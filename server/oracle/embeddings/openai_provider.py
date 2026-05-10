from __future__ import annotations

import time

import structlog
from openai import AsyncOpenAI

from oracle.core.config import settings

logger = structlog.get_logger()


class OpenAIEmbeddingProvider:
    """Concrete embedding provider backed by OpenAI text-embedding-3-small.

    Uses the official openai Python SDK's async client.  The client is
    instantiated once per provider instance; callers should treat a single
    provider as a long-lived object (e.g. module-level singleton via the
    factory).

    Args:
        model: OpenAI embedding model name.
        api_key: Override the API key from settings.  Primarily used in tests
                 so the provider can be constructed without a real key reaching
                 the network.
    """

    def __init__(self, model: str = "text-embedding-3-small", api_key: str | None = None) -> None:
        self._model = model
        if api_key is None:
            cfg_key = settings.openai_api_key
            if cfg_key is None:
                raise ValueError("OPENAI_API_KEY is not set in configuration")
            resolved = cfg_key.get_secret_value()
            if not resolved:
                raise ValueError("OPENAI_API_KEY is empty in configuration")
            api_key = resolved
        self._client = AsyncOpenAI(api_key=api_key)

    @property
    def name(self) -> str:
        return self._model

    async def embed_batch(self, texts: list[str]) -> list[list[float]]:
        """Embed *texts* via the OpenAI embeddings API.

        Logs chunk count, total tokens in the response, and request latency.
        Exceptions from the OpenAI client propagate unchanged.
        """
        start = time.monotonic()

        response = await self._client.embeddings.create(
            model=self._model,
            input=texts,
        )

        elapsed_ms = (time.monotonic() - start) * 1000
        total_tokens = response.usage.total_tokens if response.usage else None

        logger.info(
            "embeddings_created",
            provider=self._model,
            batch_size=len(texts),
            total_tokens=total_tokens,
            latency_ms=round(elapsed_ms, 1),
        )

        # The API guarantees order matches input, but sort by index to be safe.
        sorted_data = sorted(response.data, key=lambda d: d.index)
        return [d.embedding for d in sorted_data]
