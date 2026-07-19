from __future__ import annotations

from grove.embeddings.chunker import chunk
from grove.embeddings.factory import get_embedding_provider
from grove.embeddings.provider import EmbeddingProvider
from grove.embeddings.tokenizer import count_tokens

# bge-m3 (1024-d) — the embedding model for Grove's local-inference deployment
# (#518). Must match the vector column width in alembic/versions/0002-0004.
EMBEDDING_DIM = 1024
WHOLE_VS_CHUNKS_THRESHOLD = 500

__all__ = [
    "EMBEDDING_DIM",
    "WHOLE_VS_CHUNKS_THRESHOLD",
    "EmbeddingProvider",
    "chunk",
    "count_tokens",
    "get_embedding_provider",
]
