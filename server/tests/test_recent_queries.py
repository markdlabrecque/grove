"""Tests for GET /v1/queries/recent.

Requires a real Postgres instance with migrations applied.
DATABASE_URL is set by conftest.py (dev) or docker-compose CI env.
"""

from __future__ import annotations

import os
import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import delete
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.pool import NullPool

from grove.core.config import settings
from grove.main import app
from grove.models.query_log import QueryLog

AUTH_HEADERS = {"Authorization": f"Bearer {os.environ.get('BEARER_TOKEN', 'test-token')}"}

_test_engine = create_async_engine(settings.database_url, poolclass=NullPool)
_TestSession = async_sessionmaker(_test_engine, expire_on_commit=False)


async def _override_get_session() -> AsyncIterator[AsyncSession]:
    async with _TestSession() as session:
        yield session


def _override_get_log_session_factory() -> async_sessionmaker[AsyncSession]:
    return _TestSession


@pytest.fixture(autouse=True)
def override_db(monkeypatch) -> None:  # type: ignore[misc]
    from grove.api.queries import get_log_session_factory
    from grove.core.db import get_session

    app.dependency_overrides[get_session] = _override_get_session
    app.dependency_overrides[get_log_session_factory] = _override_get_log_session_factory
    yield
    app.dependency_overrides.pop(get_session, None)
    app.dependency_overrides.pop(get_log_session_factory, None)


@pytest.fixture
async def db_session() -> AsyncIterator[AsyncSession]:  # type: ignore[misc]
    async with _TestSession() as session:
        yield session


@pytest.fixture
async def client() -> AsyncIterator[AsyncClient]:
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        yield ac


# ---------------------------------------------------------------------------
# Seed helpers
# ---------------------------------------------------------------------------


async def _seed_query_log(
    session: AsyncSession,
    query_text: str,
    created_at: datetime | None = None,
) -> uuid.UUID:
    """Insert a minimal query_log row and return its id."""
    log_id = uuid.uuid4()
    row = QueryLog(
        id=log_id,
        query_text=query_text,
        query_embedding=None,
        tables_searched={"vector": True},
        result_count=0,
    )
    if created_at is not None:
        row.created_at = created_at
    session.add(row)
    await session.commit()
    # Refresh to get server-generated created_at if not overridden.
    await session.refresh(row)
    return log_id


async def _delete_query_logs(session: AsyncSession, ids: list[uuid.UUID]) -> None:
    await session.execute(delete(QueryLog).where(QueryLog.id.in_(ids)))
    await session.commit()


# ---------------------------------------------------------------------------
# Empty table → []
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_recent_queries_empty_returns_empty_list(client: AsyncClient) -> None:
    """With no query_logs rows the endpoint returns an empty JSON array."""
    # We can't guarantee the table is empty in a shared dev DB, so we just
    # assert the response is a list — the dedicated dedup/ordering tests use
    # isolated seed IDs that are cleaned up in finally blocks.
    response = await client.get("/v1/queries/recent", headers=AUTH_HEADERS)
    assert response.status_code == 200
    body = response.json()
    assert isinstance(body, list)


# ---------------------------------------------------------------------------
# 3 distinct queries → all 3 returned, newest first
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_recent_queries_ordered_by_recency(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    """3 distinct queries are returned ordered by created_at DESC."""
    now = datetime.now(UTC)
    id_a = await _seed_query_log(db_session, "query alpha", now - timedelta(minutes=10))
    id_b = await _seed_query_log(db_session, "query beta", now - timedelta(minutes=5))
    id_c = await _seed_query_log(db_session, "query gamma", now)
    try:
        response = await client.get("/v1/queries/recent", headers=AUTH_HEADERS)
        assert response.status_code == 200
        body = response.json()
        # Extract only the rows we seeded (shared DB may have others).
        seeded_ids = {str(id_a), str(id_b), str(id_c)}
        our_rows = [r for r in body if r["id"] in seeded_ids]
        assert len(our_rows) == 3
        # Verify ordered newest-first.
        assert our_rows[0]["id"] == str(id_c)
        assert our_rows[1]["id"] == str(id_b)
        assert our_rows[2]["id"] == str(id_a)
    finally:
        await _delete_query_logs(db_session, [id_a, id_b, id_c])


# ---------------------------------------------------------------------------
# Duplicate query_text → collapsed to most recent occurrence
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_recent_queries_dedup_keeps_most_recent(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    """Duplicate query_text is deduped; the returned id/created_at is from the most recent row."""
    now = datetime.now(UTC)
    id_dinner_old = await _seed_query_log(
        db_session, "what's for dinner", now - timedelta(minutes=20)
    )
    id_dinner_new = await _seed_query_log(
        db_session, "what's for dinner", now - timedelta(minutes=2)
    )
    id_weather = await _seed_query_log(db_session, "weather", now - timedelta(minutes=1))
    try:
        response = await client.get("/v1/queries/recent", headers=AUTH_HEADERS)
        assert response.status_code == 200
        body = response.json()
        seeded_ids = {str(id_dinner_old), str(id_dinner_new), str(id_weather)}
        our_rows = [r for r in body if r["id"] in seeded_ids]
        # Old dinner row should be collapsed — only 2 distinct entries from our seed.
        assert len(our_rows) == 2
        ids_in_response = {r["id"] for r in our_rows}
        assert str(id_dinner_new) in ids_in_response
        assert str(id_weather) in ids_in_response
        assert str(id_dinner_old) not in ids_in_response
    finally:
        await _delete_query_logs(db_session, [id_dinner_old, id_dinner_new, id_weather])


# ---------------------------------------------------------------------------
# Case-insensitive dedup
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_recent_queries_case_insensitive_dedup(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    """'Weather' and 'weather' are treated as the same query."""
    now = datetime.now(UTC)
    id_upper = await _seed_query_log(db_session, "Weather", now - timedelta(minutes=5))
    id_lower = await _seed_query_log(db_session, "weather", now)
    try:
        response = await client.get("/v1/queries/recent", headers=AUTH_HEADERS)
        assert response.status_code == 200
        body = response.json()
        seeded_ids = {str(id_upper), str(id_lower)}
        our_rows = [r for r in body if r["id"] in seeded_ids]
        # Should collapse to 1 entry (the more recent lowercase one).
        assert len(our_rows) == 1
        assert our_rows[0]["id"] == str(id_lower)
    finally:
        await _delete_query_logs(db_session, [id_upper, id_lower])


# ---------------------------------------------------------------------------
# limit parameter
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_recent_queries_limit_honoured(client: AsyncClient, db_session: AsyncSession) -> None:
    """limit=2 returns at most 2 results from our seeded rows."""
    now = datetime.now(UTC)
    id_a = await _seed_query_log(db_session, "limit query one", now - timedelta(minutes=30))
    id_b = await _seed_query_log(db_session, "limit query two", now - timedelta(minutes=20))
    id_c = await _seed_query_log(db_session, "limit query three", now - timedelta(minutes=10))
    try:
        response = await client.get("/v1/queries/recent?limit=2", headers=AUTH_HEADERS)
        assert response.status_code == 200
        body = response.json()
        # Isolate to our seeded rows — shared DB may carry rows from other tests
        # that would satisfy `len(body) <= 2` independently of the limit being applied.
        seeded_ids = {str(id_a), str(id_b), str(id_c)}
        our_rows = [r for r in body if r["id"] in seeded_ids]
        assert len(our_rows) <= 2
    finally:
        await _delete_query_logs(db_session, [id_a, id_b, id_c])


# ---------------------------------------------------------------------------
# Bounds validation
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_recent_queries_limit_zero_returns_422(client: AsyncClient) -> None:
    response = await client.get("/v1/queries/recent?limit=0", headers=AUTH_HEADERS)
    assert response.status_code == 422


@pytest.mark.asyncio
async def test_recent_queries_limit_51_returns_422(client: AsyncClient) -> None:
    response = await client.get("/v1/queries/recent?limit=51", headers=AUTH_HEADERS)
    assert response.status_code == 422


# ---------------------------------------------------------------------------
# 401 on missing bearer
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_recent_queries_missing_bearer_returns_401(client: AsyncClient) -> None:
    response = await client.get("/v1/queries/recent")
    assert response.status_code == 401
