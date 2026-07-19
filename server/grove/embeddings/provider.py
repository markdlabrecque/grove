from __future__ import annotations

from typing import Protocol, runtime_checkable


@runtime_checkable
class EmbeddingProvider(Protocol):
    """Abstract interface for embedding providers.

    All implementations must be async-safe and stateless beyond configuration.
    """

    @property
    def name(self) -> str:
        """Human-readable provider/model identifier used in logs and DB records."""
        ...

    async def embed_batch(self, texts: list[str]) -> list[list[float]]:
        """Embed a batch of texts and return one vector per input.

        Args:
            texts: Non-empty list of strings to embed.

        Returns:
            List of float vectors in the same order as *texts*.  Each vector
            has length ``EMBEDDING_DIM`` (1024 for bge-m3, the default).

        Raises:
            Any exception from the underlying HTTP client propagates — callers
            are responsible for retry / error handling.
        """
        ...
