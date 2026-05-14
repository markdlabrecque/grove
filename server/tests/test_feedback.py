"""Tests for POST /v1/queries/{id}/feedback.

Requires a real Postgres instance with migrations applied.
DATABASE_URL is set by conftest.py (dev) or docker-compose CI env.
"""

from __future__ import annotations

import os
import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import delete
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.pool import NullPool

from oracle.core.config import settings
from oracle.main import app
from oracle.models.query_log import QueryLog

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
    from oracle.api.queries import get_log_session_factory
    from oracle.core.db import get_session

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


async def _seed_query_log(session: AsyncSession) -> uuid.UUID:
    """Insert a minimal query_log row and return its id."""
    log_id = uuid.uuid4()
    row = QueryLog(
        id=log_id,
        query_text="test query",
        query_embedding=None,
        tables_searched={"vector": True},
        result_count=0,
    )
    session.add(row)
    await session.commit()
    return log_id


async def _delete_query_log(session: AsyncSession, log_id: uuid.UUID) -> None:
    await session.execute(delete(QueryLog).where(QueryLog.id == log_id))
    await session.commit()


# ---------------------------------------------------------------------------
# Happy path — positive feedback
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_feedback_positive_sets_columns(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    log_id = await _seed_query_log(db_session)
    before = datetime.now(UTC)
    try:
        response = await client.post(
            f"/v1/queries/{log_id}/feedback",
            json={"feedback": "positive"},
            headers=AUTH_HEADERS,
        )
        assert response.status_code == 204
        assert response.content == b""

        # Reload from DB in a fresh session to avoid stale state.
        async with _TestSession() as verify_session:
            row = await verify_session.get(QueryLog, log_id)
            assert row is not None
            assert row.user_feedback == "positive"
            assert row.feedback_at is not None
            assert row.feedback_at >= before
    finally:
        await _delete_query_log(db_session, log_id)


# ---------------------------------------------------------------------------
# Happy path — negative feedback
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_feedback_negative_sets_columns(
    client: AsyncClient, db_session: AsyncSession
) -> None:
    log_id = await _seed_query_log(db_session)
    before = datetime.now(UTC)
    try:
        response = await client.post(
            f"/v1/queries/{log_id}/feedback",
            json={"feedback": "negative"},
            headers=AUTH_HEADERS,
        )
        assert response.status_code == 204

        async with _TestSession() as verify_session:
            row = await verify_session.get(QueryLog, log_id)
            assert row is not None
            assert row.user_feedback == "negative"
            assert row.feedback_at is not None
            assert row.feedback_at >= before
    finally:
        await _delete_query_log(db_session, log_id)


# ---------------------------------------------------------------------------
# Idempotent overwrite — positive → negative → positive
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_feedback_idempotent_overwrite(client: AsyncClient, db_session: AsyncSession) -> None:
    log_id = await _seed_query_log(db_session)
    try:
        # First write: positive
        r1 = await client.post(
            f"/v1/queries/{log_id}/feedback",
            json={"feedback": "positive"},
            headers=AUTH_HEADERS,
        )
        assert r1.status_code == 204

        async with _TestSession() as s:
            row1 = await s.get(QueryLog, log_id)
            assert row1 is not None
            first_feedback_at = row1.feedback_at

        # Second write: negative — overwrites
        r2 = await client.post(
            f"/v1/queries/{log_id}/feedback",
            json={"feedback": "negative"},
            headers=AUTH_HEADERS,
        )
        assert r2.status_code == 204

        async with _TestSession() as s:
            row2 = await s.get(QueryLog, log_id)
            assert row2 is not None
            assert row2.user_feedback == "negative"
            # feedback_at should be updated (or at minimum not earlier than first write)
            assert row2.feedback_at is not None
            assert row2.feedback_at >= first_feedback_at

        # Third write: back to positive
        r3 = await client.post(
            f"/v1/queries/{log_id}/feedback",
            json={"feedback": "positive"},
            headers=AUTH_HEADERS,
        )
        assert r3.status_code == 204

        async with _TestSession() as s:
            row3 = await s.get(QueryLog, log_id)
            assert row3 is not None
            assert row3.user_feedback == "positive"
    finally:
        await _delete_query_log(db_session, log_id)


# ---------------------------------------------------------------------------
# 404 on unknown query_id
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_feedback_unknown_query_id_returns_404(client: AsyncClient) -> None:
    unknown_id = uuid.uuid4()
    response = await client.post(
        f"/v1/queries/{unknown_id}/feedback",
        json={"feedback": "positive"},
        headers=AUTH_HEADERS,
    )
    assert response.status_code == 404


# ---------------------------------------------------------------------------
# 401 on missing bearer
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_feedback_missing_bearer_returns_401(client: AsyncClient) -> None:
    some_id = uuid.uuid4()
    response = await client.post(
        f"/v1/queries/{some_id}/feedback",
        json={"feedback": "positive"},
    )
    assert response.status_code == 401


# ---------------------------------------------------------------------------
# 422 on invalid feedback value
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_feedback_invalid_value_returns_422(client: AsyncClient) -> None:
    some_id = uuid.uuid4()
    response = await client.post(
        f"/v1/queries/{some_id}/feedback",
        json={"feedback": "meh"},
        headers=AUTH_HEADERS,
    )
    assert response.status_code == 422
