from __future__ import annotations

from oracle.embeddings.chunker import chunk
from oracle.embeddings.factory import get_embedding_provider
from oracle.embeddings.provider import EmbeddingProvider
from oracle.embeddings.tokenizer import count_tokens

EMBEDDING_DIM = 1536
WHOLE_VS_CHUNKS_THRESHOLD = 500

__all__ = [
    "EMBEDDING_DIM",
    "WHOLE_VS_CHUNKS_THRESHOLD",
    "EmbeddingProvider",
    "chunk",
    "count_tokens",
    "get_embedding_provider",
]
