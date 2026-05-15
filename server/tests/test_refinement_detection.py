"""Tests for query refinement detection (ticket #176).

Covers:
- Refinement detected: similar query within 5 minutes.
- Not detected: different query within 5 minutes (similarity < threshold).
- Not detected: similar query older than 5 minutes.
- Not detected: no prior query at all.
- RefinementConfig thresholds are reachable via settings (no magic numbers inline).

Uses the real Postgres+pgvector DB — same pattern as test_queries.py.
The `detect_refinement` function is exercised directly (no HTTP layer needed),
since it is pure-logic with a deterministic input → output contract.
"""

from __future__ import annotations

import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import delete
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.pool import NullPool

from oracle.core.config import settings
from oracle.embeddings import EMBEDDING_DIM
from oracle.models.query_log import QueryLog

_test_engine = create_async_engine(settings.database_url, poolclass=NullPool)
_TestSession = async_sessionmaker(_test_engine, expire_on_commit=False)


@pytest.fixture
async def db_session() -> AsyncIterator[AsyncSession]:  # type: ignore[misc]
    async with _TestSession() as session:
        yield session


# Two vectors with cosine similarity ≈ 1.0 (identical) — placed at the END of
# the embedding so they are orthogonal to anything other test modules might
# insert at the start of the vector (e.g. ``test_queries.py`` uses
# ``[1.0] + [0.0]*(D-1)`` at index 0). Keeping our refinement vectors at
# index D-1 means cross-module rows can never reach the similarity threshold.
_SIMILAR_VEC = [0.0] * (EMBEDDING_DIM - 1) + [1.0]
# Orthogonal to _SIMILAR_VEC — cosine similarity = 0.0.
_DIFFERENT_VEC = [0.0] * (EMBEDDING_DIM - 2) + [1.0, 0.0]


async def _insert_prior_log(
    session: AsyncSession,
    embedding: list[float],
    created_at: datetime,
) -> uuid.UUID:
    """Insert a bare query_log row (no memory refs) for refinement-detection testing."""
    row = QueryLog(
        id=uuid.uuid4(),
        query_text="prior query text",
        query_embedding=embedding,
        tables_searched={"vector": True},
        result_count=0,
        created_at=created_at,
    )
    session.add(row)
    await session.commit()
    await session.refresh(row)
    return row.id


async def _cleanup_log(session: AsyncSession, log_id: uuid.UUID) -> None:
    await session.execute(delete(QueryLog).where(QueryLog.id == log_id))
    await session.commit()


# ---------------------------------------------------------------------------
# RefinementConfig is reachable via settings
# ---------------------------------------------------------------------------


def test_refinement_config_on_settings() -> None:
    """RefinementConfig is accessible via settings.refinement — no magic numbers inline."""
    from oracle.core.config import RefinementConfig

    assert hasattr(settings, "refinement"), "settings must have a 'refinement' attribute"
    cfg = settings.refinement
    assert isinstance(cfg, RefinementConfig)
    assert cfg.window_minutes > 0
    assert 0.0 < cfg.similarity_threshold <= 1.0


# ---------------------------------------------------------------------------
# detect_refinement: similar query within window → is_refinement=True
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_detect_refinement_similar_within_window(db_session: AsyncSession) -> None:
    """Similar query within 5-minute window is marked as a refinement."""
    from oracle.retrieval.refinement import detect_refinement

    now = datetime.now(UTC)
    recent = now - timedelta(minutes=2)

    prior_id = await _insert_prior_log(db_session, _SIMILAR_VEC, recent)
    try:
        result = await detect_refinement(_TestSession, _SIMILAR_VEC)
        assert result is not None, "Expected a refinement match"
        is_refinement, parent_id = result
        assert is_refinement is True
        assert parent_id == prior_id
    finally:
        await _cleanup_log(db_session, prior_id)


# ---------------------------------------------------------------------------
# detect_refinement: different query within window → None (no refinement)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_detect_refinement_different_query_within_window(db_session: AsyncSession) -> None:
    """Orthogonal query within 5-minute window is NOT a refinement."""
    from oracle.retrieval.refinement import detect_refinement

    now = datetime.now(UTC)
    recent = now - timedelta(minutes=2)

    prior_id = await _insert_prior_log(db_session, _SIMILAR_VEC, recent)
    try:
        # New query uses _DIFFERENT_VEC — similarity = 0.0, below threshold.
        result = await detect_refinement(_TestSession, _DIFFERENT_VEC)
        assert result is None, "Orthogonal query must not be detected as refinement"
    finally:
        await _cleanup_log(db_session, prior_id)


# ---------------------------------------------------------------------------
# detect_refinement: similar query outside window → None (no refinement)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_detect_refinement_similar_outside_window(db_session: AsyncSession) -> None:
    """Similar query older than 5 minutes is NOT a refinement."""
    from oracle.retrieval.refinement import detect_refinement

    now = datetime.now(UTC)
    old = now - timedelta(minutes=10)

    prior_id = await _insert_prior_log(db_session, _SIMILAR_VEC, old)
    try:
        result = await detect_refinement(_TestSession, _SIMILAR_VEC)
        assert result is None, "Old query must not be detected as refinement"
    finally:
        await _cleanup_log(db_session, prior_id)


# ---------------------------------------------------------------------------
# detect_refinement: no prior query → None (no refinement)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_detect_refinement_no_prior_query() -> None:
    """When there are no prior query_logs within the window, returns None."""
    from oracle.retrieval.refinement import detect_refinement

    # Use a session factory backed by the test DB — ensure any prior rows
    # are outside the window or absent by using a fresh synthetic vector
    # that won't match anything meaningful.
    far_future_vec = [0.0] * (EMBEDDING_DIM - 1) + [1.0]

    # We can't guarantee the DB is empty, but we can at minimum confirm the
    # function returns None when there's nothing within 0 minutes — use a
    # zero-width window via a custom config to isolate.
    from oracle.core.config import RefinementConfig

    zero_window_cfg = RefinementConfig(window_minutes=0, similarity_threshold=0.85)
    result = await detect_refinement(_TestSession, far_future_vec, config=zero_window_cfg)
    assert result is None
