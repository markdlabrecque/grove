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
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from oracle.core.db import SessionLocal, get_session
from oracle.embeddings import get_embedding_provider
from oracle.embeddings.tokenizer import count_tokens
from oracle.models.memory import Memory, MemoryChunk
from oracle.models.query_log import QueryLog


def get_log_session_factory() -> async_sessionmaker[AsyncSession]:
    """Dependency that returns the session factory used for query_log writes.

    A dedicated dependency (rather than a direct SessionLocal reference) lets
    tests override it with the test session factory so log writes use the same
    DB connection that the test can inspect.
    """
    return SessionLocal


logger = structlog.get_logger()

router = APIRouter()

_SNIPPET_LEN = 140


# ---------------------------------------------------------------------------
# Request / response schemas
# ---------------------------------------------------------------------------


class QueryRequest(BaseModel):
    query: str = Field(..., min_length=1)
    limit: int = Field(default=10, ge=1, le=50)
    min_similarity: float | None = Field(default=None, ge=0.0, le=1.0)

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
# Query log helpers (best-effort — failures must not surface to the caller)
# ---------------------------------------------------------------------------

_TABLES_SEARCHED = ["memories", "memory_chunks"]


async def _insert_query_log(
    session_factory: async_sessionmaker[AsyncSession],
    query_text: str,
    query_embedding: list[float],
) -> uuid.UUID | None:
    """Insert a query_log row before the search. Returns the new row id or None on failure."""
    log_id = uuid.uuid4()
    try:
        async with session_factory() as log_session:
            log_session.add(
                QueryLog(
                    id=log_id,
                    query_text=query_text,
                    query_embedding=query_embedding,
                    tables_searched=_TABLES_SEARCHED,
                    # result_count is NOT NULL — use 0 as a placeholder until the
                    # update call fills in the real value after search completes.
                    result_count=0,
                )
            )
            await log_session.commit()
    except Exception as exc:
        logger.warning("query_log_insert_failed", query_log_id=str(log_id), error=str(exc))
        return None
    return log_id


async def _update_query_log(
    session_factory: async_sessionmaker[AsyncSession],
    log_id: uuid.UUID,
    result_count: int,
    returned_memory_ids: list[uuid.UUID],
) -> None:
    """Update the query_log row with post-search result data. Best-effort."""
    try:
        async with session_factory() as log_session:
            row = await log_session.get(QueryLog, log_id)
            if row is not None:
                row.result_count = result_count
                row.returned_memory_ids = returned_memory_ids
                await log_session.commit()
    except Exception as exc:
        logger.warning("query_log_update_failed", query_log_id=str(log_id), error=str(exc))


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
    log_factory: Annotated[async_sessionmaker[AsyncSession], Depends(get_log_session_factory)],
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

    # Insert the query log row before the search (best-effort).
    log_id = await _insert_query_log(log_factory, body.query, query_vec)

    # Run whole-memory and chunk searches sequentially on the shared session.
    # asyncio.gather over the same SQLAlchemy AsyncSession is unsafe — the
    # session state machine is not re-entrant. Sequential is correct here and
    # fast enough at personal corpus scale.
    search_start = time.monotonic()
    whole_hits = await _search_whole_memories(session, query_vec, body.limit)
    chunk_hits = await _search_chunks(session, query_vec, body.limit)
    search_latency_ms = (time.monotonic() - search_start) * 1000

    results, truncated = _merge_hits(whole_hits, chunk_hits, body.limit, body.min_similarity)

    # Update the query log with result data (best-effort).
    if log_id is not None:
        await _update_query_log(
            log_factory,
            log_id,
            result_count=len(results),
            returned_memory_ids=[r.memory_id for r in results],
        )

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
        query_log_id=str(log_id) if log_id else None,
    )

    return QueryResponse(
        results=results,
        query_token_count=query_token_count,
        latency_ms=round(total_latency_ms, 1),
    )
