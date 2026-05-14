"""POST /v1/queries — hybrid retrieval over memories with LLM synthesis.

Flow:
  1. Embed the query via OpenAI text-embedding-3-small.
  2. Run cosine similarity over memories and memory_chunks (vector path).
  3. Classify query intent via a cheap OpenRouter call (intent router).
  4. For each non-general intent, run a structured query against the matching
     specialised table (decisions / people_interactions / tasks / appointments).
     Empty tables are skipped efficiently via an EXISTS check.
  5. Merge vector and specialised hits, dedup by memory_id keeping highest score.
     Specialised hits receive a small score boost (intent_match_score_boost).
  6. Synthesise a natural-language answer with inline [#memory_id] citations.

Both synthesis and intent-router failures degrade gracefully:
  - Intent router failure → falls through to vector-only results.
  - Synthesis failure → returns answer=null with ranked sources.
"""

from __future__ import annotations

import time
import uuid
from decimal import Decimal
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


class SourceItem(BaseModel):
    """Per-memory source entry in the synthesis response."""

    memory_id: uuid.UUID
    excerpt: str
    score: float
    matched_via: Literal["whole", "chunk", "specialised"]
    matched_chunk_index: int | None


class QueryResponse(BaseModel):
    # Synthesis answer — null when synthesis failed or no sources were found.
    answer: str | None
    # Ranked sources used to compose the answer (replaces the old `results` list).
    # iOS code that reads `results` must migrate to `sources`; the field is
    # intentionally renamed to signal the shape change.
    sources: list[SourceItem]
    query_id: uuid.UUID
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
) -> tuple[list[SourceItem], bool]:
    """Merge whole-memory and chunk hits by memory_id, keeping best score.

    Returns (ranked_sources, truncated) where truncated is True when we had
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

    sources = [
        SourceItem(
            memory_id=h["memory_id"],
            excerpt=h["snippet"],
            score=round(h["score"], 6),
            matched_via=h["matched_via"],
            matched_chunk_index=h["matched_chunk_index"],
        )
        for h in page
    ]
    return sources, truncated


# ---------------------------------------------------------------------------
# Query log helpers (best-effort — failures must not surface to the caller)
# ---------------------------------------------------------------------------

# Initial tables_searched placeholder written before the search starts.
# The update call replaces this with the actual per-table outcomes.
_TABLES_SEARCHED_INITIAL: dict = {
    "vector": True,
    "decisions": "skipped",
    "people_interactions": "skipped",
    "tasks": "skipped",
    "appointments": "skipped",
}


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
                    tables_searched=_TABLES_SEARCHED_INITIAL,
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
    tables_searched: dict,
) -> None:
    """Update the query_log row with post-search result data. Best-effort."""
    try:
        async with session_factory() as log_session:
            row = await log_session.get(QueryLog, log_id)
            if row is not None:
                row.result_count = result_count
                row.returned_memory_ids = returned_memory_ids
                row.tables_searched = tables_searched
                await log_session.commit()
    except Exception as exc:
        logger.warning("query_log_update_failed", query_log_id=str(log_id), error=str(exc))


async def _stamp_synthesis(
    session_factory: async_sessionmaker[AsyncSession],
    log_id: uuid.UUID,
    model: str,
    input_tokens: int,
    output_tokens: int,
    cost_usd: float | None,
) -> None:
    """Stamp synthesis telemetry onto the query_log row. Best-effort."""
    try:
        async with session_factory() as log_session:
            row = await log_session.get(QueryLog, log_id)
            if row is not None:
                row.synthesis_model = model
                row.synthesis_input_tokens = input_tokens
                row.synthesis_output_tokens = output_tokens
                row.synthesis_cost = Decimal(str(cost_usd)) if cost_usd is not None else None
                await log_session.commit()
    except Exception as exc:
        logger.warning("synthesis_log_stamp_failed", query_log_id=str(log_id), error=str(exc))


async def _stamp_intent_router(
    session_factory: async_sessionmaker[AsyncSession],
    log_id: uuid.UUID,
    model: str,
    input_tokens: int,
    output_tokens: int,
    cost_usd: float | None,
) -> None:
    """Stamp intent-router telemetry onto the query_log row. Best-effort."""
    try:
        async with session_factory() as log_session:
            row = await log_session.get(QueryLog, log_id)
            if row is not None:
                row.intent_router_model = model
                row.intent_router_input_tokens = input_tokens
                row.intent_router_output_tokens = output_tokens
                row.intent_router_cost = Decimal(str(cost_usd)) if cost_usd is not None else None
                await log_session.commit()
    except Exception as exc:
        logger.warning("intent_router_log_stamp_failed", query_log_id=str(log_id), error=str(exc))


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
    from oracle.core.config import settings
    from oracle.retrieval.intent_router import (
        classify_intent,
        merge_with_specialised,
        run_specialised_queries,
    )
    from oracle.retrieval.synthesizer import synthesize

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

    # ---------------------------------------------------------------------------
    # Intent router — classify query intent and run specialised-table retrieval.
    # On failure: degrade gracefully to vector-only results.
    # ---------------------------------------------------------------------------
    api_key = settings.openrouter_api_key.get_secret_value() if settings.openrouter_api_key else ""

    # tables_searched records the per-table outcome for every query.
    tables_searched: dict = {"vector": True}
    all_hits = whole_hits + chunk_hits

    if api_key:
        try:
            intent_result = await classify_intent(
                body.query,
                api_key=api_key,
                model=settings.intent_router_model,
            )
            if log_id is not None:
                await _stamp_intent_router(
                    log_factory,
                    log_id,
                    model=intent_result.model,
                    input_tokens=intent_result.prompt_tokens,
                    output_tokens=intent_result.completion_tokens,
                    cost_usd=intent_result.cost_usd,
                )

            specialised = await run_specialised_queries(session, intent_result.intents, body.query)
            tables_searched.update(specialised.tables_searched)

            if specialised.hits:
                all_hits = merge_with_specialised(
                    all_hits,
                    specialised.hits,
                    settings.intent_match_score_boost,
                )
            else:
                # No specialised hits — still record the per-table outcomes.
                # all_hits stays as the pure vector result.
                pass

        except Exception as exc:
            # Intent router failure is non-fatal — degrade to vector-only.
            logger.warning(
                "intent_router_failed",
                query_log_id=str(log_id) if log_id else None,
                error=str(exc),
            )
            # Ensure tables_searched is still populated even on failure.
            for tbl in ("decisions", "people_interactions", "tasks", "appointments"):
                tables_searched.setdefault(tbl, "skipped")
    else:
        logger.warning("intent_router_skipped_no_api_key")
        for tbl in ("decisions", "people_interactions", "tasks", "appointments"):
            tables_searched[tbl] = "skipped"

    # Load content for specialised-only hits that have no snippet from vector search.
    # These are memories that appeared only via the specialised-table path.
    specialised_only_ids = [
        h["memory_id"]
        for h in all_hits
        if h.get("matched_via") == "specialised" and not h.get("snippet")
    ]
    if specialised_only_ids:
        content_rows = await session.execute(
            select(Memory.id, Memory.content, Memory.captured_at, Memory.source_modality).where(
                Memory.id.in_(specialised_only_ids)
            )
        )
        content_map = {row.id: row for row in content_rows}
        all_hits = [
            {
                **h,
                "snippet": _snippet(content_map[h["memory_id"]].content)
                if h.get("matched_via") == "specialised" and h["memory_id"] in content_map
                else h.get("snippet", ""),
            }
            for h in all_hits
        ]

    sources, truncated = _merge_hits(all_hits, [], body.limit, body.min_similarity)

    # Update the query log with result data (best-effort).
    if log_id is not None:
        await _update_query_log(
            log_factory,
            log_id,
            result_count=len(sources),
            returned_memory_ids=[s.memory_id for s in sources],
            tables_searched=tables_searched,
        )

    # ---------------------------------------------------------------------------
    # RAG synthesis — compose an answer over the retrieved sources.
    # On failure: degrade gracefully to answer=None, keep sources populated.
    # ---------------------------------------------------------------------------
    answer: str | None = None

    if sources and api_key:
        try:
            synthesis_result = await synthesize(
                body.query,
                [{"memory_id": str(s.memory_id), "excerpt": s.excerpt} for s in sources],
                api_key=api_key,
                model=settings.synthesis_model,
            )
            answer = synthesis_result.answer
            if log_id is not None:
                await _stamp_synthesis(
                    log_factory,
                    log_id,
                    model=settings.synthesis_model,
                    input_tokens=synthesis_result.prompt_tokens,
                    output_tokens=synthesis_result.completion_tokens,
                    cost_usd=synthesis_result.cost_usd,
                )
        except Exception as exc:
            # Synthesis failure is non-fatal — log it and fall through with answer=None.
            logger.warning(
                "synthesis_failed",
                query_log_id=str(log_id) if log_id else None,
                error=str(exc),
            )
    elif not api_key:
        logger.warning("synthesis_skipped_no_api_key")

    total_latency_ms = (time.monotonic() - total_start) * 1000

    logger.info(
        "query_executed",
        query_token_count=query_token_count,
        result_count=len(sources),
        embedding_latency_ms=round(embedding_latency_ms, 1),
        search_latency_ms=round(search_latency_ms, 1),
        total_latency_ms=round(total_latency_ms, 1),
        truncated_results=truncated,
        limit=body.limit,
        min_similarity=body.min_similarity,
        query_log_id=str(log_id) if log_id else None,
        synthesis_answer_present=answer is not None,
        intents=tables_searched,
    )

    return QueryResponse(
        answer=answer,
        sources=sources,
        query_id=log_id or uuid.uuid4(),
        query_token_count=query_token_count,
        latency_ms=round(total_latency_ms, 1),
    )
