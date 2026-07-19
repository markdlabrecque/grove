from __future__ import annotations

import time

import structlog
from openai import AsyncOpenAI

from grove.core.config import settings

logger = structlog.get_logger()


class OpenAIEmbeddingProvider:
    """Embedding provider using the OpenAI embeddings API shape.

    Defaults (via settings) to bge-m3 served locally through an
    OpenAI-compatible endpoint (e.g. Ollama); also works against real OpenAI
    models when pointed at api.openai.com with an OpenAI model name.

    Uses the official openai Python SDK's async client.  The client is
    instantiated once per provider instance; callers should treat a single
    provider as a long-lived object (e.g. module-level singleton via the
    factory).

    Args:
        model: OpenAI embedding model name.
        api_key: Override the API key from settings.  Primarily used in tests
                 so the provider can be constructed without a real key reaching
                 the network.
        base_url: Override the API base URL. None uses the OpenAI SDK default
                   (api.openai.com); pass a local OpenAI-compatible endpoint
                   (e.g. Ollama's http://host.docker.internal:11434/v1) to
                   embed against a self-hosted model.
    """

    def __init__(
        self,
        model: str = "text-embedding-3-small",
        api_key: str | None = None,
        base_url: str | None = None,
    ) -> None:
        self._model = model
        if api_key is None:
            cfg_key = settings.openai_api_key
            api_key = cfg_key.get_secret_value() if cfg_key is not None else ""
        # The openai SDK raises both at construction time and during auth-header
        # building when the key is empty — both fire before respx intercepts the
        # request, which breaks mocked tests.  We pass a sentinel when the key is
        # absent and suppress the construction-time check so the SDK can build
        # request objects normally.  In production OPENAI_API_KEY is always set;
        # if it somehow isn't, OpenAI returns 401 which is the right failure.
        self._client = AsyncOpenAI(
            api_key=api_key if api_key else "sk-test-placeholder",
            base_url=base_url,
            _enforce_credentials=False,
        )

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
