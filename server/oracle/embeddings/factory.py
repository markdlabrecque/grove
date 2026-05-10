from __future__ import annotations

import functools

from oracle.embeddings.openai_provider import OpenAIEmbeddingProvider
from oracle.embeddings.provider import EmbeddingProvider


@functools.lru_cache(maxsize=1)
def get_embedding_provider() -> EmbeddingProvider:
    """Return the configured embedding provider.

    V1 always returns an ``OpenAIEmbeddingProvider``.  The abstraction is in
    place so that swapping to a different model or provider in a later phase
    is a config change, not a refactor.

    The result is cached at the module level so the underlying OpenAI client
    (and its connection pool) is reused across requests.
    """
    return OpenAIEmbeddingProvider()
