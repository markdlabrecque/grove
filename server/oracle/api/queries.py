"""POST /v1/queries — vector search over memories.

Pure search: embed the query string, run cosine similarity against both
memories.embedding (whole-memory) and memory_chunks.embedding (chunked),
merge by memory_id keeping the best score per memory, and return ranked
results. No LLM synthesis — that is a follow-up ticket.
"""

from __future__ import annotations

import time
import uuid
from datetime import datetime
from typing import Annotated, Literal

import structlog
from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field, field_validator
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from oracle.core.db import get_session
from oracle.embeddings import get_embedding_provider
from oracle.embeddings.tokenizer import count_tokens
from oracle.models.memory import Memory, MemoryChunk

logger = structlog.get_logger()

router = APIRouter()

_SNIPPET_LEN = 140


# ---------------------------------------------------------------------------
# Request / response schemas
# ---------------------------------------------------------------------------


class QueryRequest(BaseModel):
    query: str = Field(..., min_length=1)
    limit: int = Field(default=10, ge=1, le=50)
    min_similarity: float | None = Field(default=None)

    @field_validator("query")
    @classmethod
    def query_must_not_be_blank(cls, v: str) -> str:
        if not v.strip():
            raise ValueError("query must not be blank after stripping whitespace")
        return v


class QueryResult(BaseModel):
    memory_id: uuid.UUID
    score: float
    matched_via: Literal["whole", "chunk"]
    matched_chunk_index: int | None
    snippet: str
    captured_at: datetime | None
    source_modality: str | None


class QueryResponse(BaseModel):
    results: list[QueryResult]
    query_token_count: int
    latency_ms: float


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _snippet(text: str) -> str:
    return text[:_SNIPPET_LEN]


async def _search_whole_memories(
    session: AsyncSession,
    query_vec: list[float],
    limit: int,
) -> list[dict]:
    """Cosine search over memories.embedding (whole-memory path)."""
    stmt = (
        select(
            Memory.id,
            Memory.captured_at,
            Memory.source_modality,
            Memory.content,
            Memory.embedding.cosine_distance(query_vec).label("distance"),
        )
        .where(Memory.embedding.is_not(None))
        .order_by(Memory.embedding.cosine_distance(query_vec))
        .limit(limit)
    )
    result = await session.execute(stmt)
    rows = result.all()
    return [
        {
            "memory_id": row.id,
            "captured_at": row.captured_at,
            "source_modality": row.source_modality,
            "score": 1.0 - float(row.distance),
            "matched_via": "whole",
            "matched_chunk_index": None,
            "snippet": _snippet(row.content),
        }
        for row in rows
    ]


async def _search_chunks(
    session: AsyncSession,
    query_vec: list[float],
    limit: int,
) -> list[dict]:
    """Cosine search over memory_chunks.embedding (chunked-memory path)."""
    stmt = (
        select(
            MemoryChunk.memory_id,
            MemoryChunk.chunk_index,
            MemoryChunk.content,
            MemoryChunk.embedding.cosine_distance(query_vec).label("distance"),
            Memory.captured_at,
            Memory.source_modality,
        )
        .join(Memory, Memory.id == MemoryChunk.memory_id)
        .order_by(MemoryChunk.embedding.cosine_distance(query_vec))
        .limit(limit)
    )
    result = await session.execute(stmt)
    rows = result.all()
    return [
        {
            "memory_id": row.memory_id,
            "captured_at": row.captured_at,
            "source_modality": row.source_modality,
            "score": 1.0 - float(row.distance),
            "matched_via": "chunk",
            "matched_chunk_index": row.chunk_index,
            "snippet": _snippet(row.content),
        }
        for row in rows
    ]


def _merge_hits(
    whole_hits: list[dict],
    chunk_hits: list[dict],
    limit: int,
    min_similarity: float | None,
) -> tuple[list[QueryResult], bool]:
    """Merge whole-memory and chunk hits by memory_id, keeping best score.

    Returns (ranked_results, truncated) where truncated is True when we had
    more candidates than limit before re-ranking.
    """
    # memory_id → best hit dict
    best: dict[uuid.UUID, dict] = {}

    for hit in whole_hits + chunk_hits:
        mid = hit["memory_id"]
        if mid not in best or hit["score"] > best[mid]["score"]:
            best[mid] = hit

    candidates = list(best.values())
    truncated = len(candidates) > limit

    # Apply similarity floor before sorting so the flag reflects pre-limit pool.
    if min_similarity is not None:
        candidates = [c for c in candidates if c["score"] >= min_similarity]

    candidates.sort(key=lambda h: h["score"], reverse=True)
    page = candidates[:limit]

    results = [
        QueryResult(
            memory_id=h["memory_id"],
            score=round(h["score"], 6),
            matched_via=h["matched_via"],
            matched_chunk_index=h["matched_chunk_index"],
            snippet=h["snippet"],
            captured_at=h["captured_at"],
            source_modality=h["source_modality"],
        )
        for h in page
    ]
    return results, truncated


# ---------------------------------------------------------------------------
# Route
# ---------------------------------------------------------------------------


@router.post(
    "/queries",
    response_model=QueryResponse,
    status_code=status.HTTP_200_OK,
)
async def post_query(
    body: QueryRequest,
    session: Annotated[AsyncSession, Depends(get_session)],
) -> QueryResponse:
    total_start = time.monotonic()

    query_token_count = count_tokens(body.query)
    provider = get_embedding_provider()

    # Embed the query string.
    embed_start = time.monotonic()
    try:
        vectors = await provider.embed_batch([body.query])
    except Exception as exc:
        logger.error("embedding_provider_error", error=str(exc))
        raise HTTPException(status_code=502, detail="Embedding provider error") from exc
    embedding_latency_ms = (time.monotonic() - embed_start) * 1000
    query_vec: list[float] = vectors[0]

    # Run whole-memory and chunk searches sequentially on the shared session.
    # asyncio.gather over the same SQLAlchemy AsyncSession is unsafe — the
    # session state machine is not re-entrant. Sequential is correct here and
    # fast enough at personal corpus scale.
    search_start = time.monotonic()
    whole_hits = await _search_whole_memories(session, query_vec, body.limit)
    chunk_hits = await _search_chunks(session, query_vec, body.limit)
    search_latency_ms = (time.monotonic() - search_start) * 1000

    results, truncated = _merge_hits(whole_hits, chunk_hits, body.limit, body.min_similarity)

    total_latency_ms = (time.monotonic() - total_start) * 1000

    logger.info(
        "query_executed",
        query_token_count=query_token_count,
        result_count=len(results),
        embedding_latency_ms=round(embedding_latency_ms, 1),
        search_latency_ms=round(search_latency_ms, 1),
        total_latency_ms=round(total_latency_ms, 1),
        truncated_results=truncated,
        limit=body.limit,
        min_similarity=body.min_similarity,
    )

    return QueryResponse(
        results=results,
        query_token_count=query_token_count,
        latency_ms=round(total_latency_ms, 1),
    )
