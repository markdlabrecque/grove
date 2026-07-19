from __future__ import annotations

import functools

from grove.core.config import settings
from grove.embeddings.openai_provider import OpenAIEmbeddingProvider
from grove.embeddings.provider import EmbeddingProvider


@functools.lru_cache(maxsize=1)
def get_embedding_provider() -> EmbeddingProvider:
    """Return the configured embedding provider.

    V1 always returns an ``OpenAIEmbeddingProvider``, using the model and
    base URL from settings (so a local OpenAI-compatible endpoint, e.g.
    Ollama, can be targeted via env vars). The abstraction is in place so
    that swapping to a different model or provider in a later phase is a
    config change, not a refactor.

    The result is cached at the module level so the underlying OpenAI client
    (and its connection pool) is reused across requests.
    """
    return OpenAIEmbeddingProvider(
        model=settings.embedding_model,
        base_url=settings.embedding_base_url,
    )
