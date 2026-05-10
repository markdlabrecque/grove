"""Tests for POST /v1/captures.

Requires a real Postgres+pgvector instance with migrations applied.
DATABASE_URL is set by conftest.py (dev) or docker-compose CI env.
"""

from __future__ import annotations

import os
import uuid
from collections.abc import AsyncIterator

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.pool import NullPool

from oracle.core.config import settings
from oracle.core.db import get_session
from oracle.models.memory import Memory

AUTH_HEADERS = {"Authorization": f"Bearer {os.environ.get('BEARER_TOKEN', 'test-token')}"}

BASE_PAYLOAD: dict = {
    "content": "I decided to keep the side project going despite the time pressure.",
    "source_modality": "text",
    "source_device": "iPhone 17 Pro",
    "captured_at": "2024-06-01T10:30:00+00:00",
}

# NullPool: each request gets its own connection, no pool reuse across coroutines.
# This prevents asyncpg "another operation is in progress" errors when the app
# engine and the test's direct session share the same event loop.
_test_engine = create_async_engine(settings.database_url, poolclass=NullPool)
_TestSession = async_sessionmaker(_test_engine, expire_on_commit=False)


async def _override_get_session() -> AsyncIterator[AsyncSession]:
    async with _TestSession() as session:
        yield session


@pytest.fixture
def payload() -> dict:
    """Return a fresh payload with a unique client_id per test."""
    return {**BASE_PAYLOAD, "client_id": str(uuid.uuid4())}


@pytest.fixture
async def db_session() -> AsyncIterator[AsyncSession]:  # type: ignore[misc]
    async with _TestSession() as session:
        yield session


@pytest.fixture(autouse=True)
def override_db(monkeypatch) -> None:  # type: ignore[misc]
    """Wire the app to use the same NullPool engine as the test's db_session.

    This is the only reliable way to avoid asyncpg "another operation is in
    progress" errors: the app and the test queries share the same pool (NullPool
    gives each call a fresh connection, so they don't race).
    """
    from oracle.main import app

    app.dependency_overrides[get_session] = _override_get_session
    yield
    app.dependency_overrides.pop(get_session, None)


# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_happy_path_creates_memory(payload: dict, db_session: AsyncSession) -> None:
    from oracle.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/v1/captures", json=payload, headers=AUTH_HEADERS)

    assert response.status_code == 201
    body = response.json()
    assert body["enriched"] is False
    assert body["client_id"] == payload["client_id"]
    assert "id" in body
    assert "captured_at" in body

    # Verify the row is actually in the DB with correct fields.
    client_id = uuid.UUID(payload["client_id"])
    result = await db_session.execute(select(Memory).where(Memory.client_id == client_id))
    row = result.scalar_one()
    assert row.content == payload["content"]
    assert row.source_modality == payload["source_modality"]
    assert row.source_device == payload["source_device"]
    assert row.language == "en"
    assert row.enriched is False
    assert row.embedding_model == "text-embedding-3-small"
    assert row.embedding is None

    # Cleanup
    await db_session.delete(row)
    await db_session.commit()


@pytest.mark.asyncio
async def test_happy_path_with_explicit_language(payload: dict, db_session: AsyncSession) -> None:
    from oracle.main import app

    payload["language"] = "fr"
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/v1/captures", json=payload, headers=AUTH_HEADERS)

    assert response.status_code == 201

    client_id = uuid.UUID(payload["client_id"])
    result = await db_session.execute(select(Memory).where(Memory.client_id == client_id))
    row = result.scalar_one()
    assert row.language == "fr"

    await db_session.delete(row)
    await db_session.commit()


# ---------------------------------------------------------------------------
# Idempotency
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_idempotent_second_post_returns_200_with_same_id(
    payload: dict, db_session: AsyncSession
) -> None:
    from oracle.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        r1 = await client.post("/v1/captures", json=payload, headers=AUTH_HEADERS)
        r2 = await client.post("/v1/captures", json=payload, headers=AUTH_HEADERS)

    assert r1.status_code == 201
    assert r2.status_code == 200
    assert r1.json()["id"] == r2.json()["id"]

    # Only one row in the DB.
    client_id = uuid.UUID(payload["client_id"])
    result = await db_session.execute(select(Memory).where(Memory.client_id == client_id))
    rows = result.scalars().all()
    assert len(rows) == 1

    await db_session.delete(rows[0])
    await db_session.commit()


# ---------------------------------------------------------------------------
# Validation — 422 cases
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_missing_required_field_returns_422() -> None:
    from oracle.main import app

    incomplete = {k: v for k, v in BASE_PAYLOAD.items() if k != "content"}
    incomplete["client_id"] = str(uuid.uuid4())
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/v1/captures", json=incomplete, headers=AUTH_HEADERS)

    assert response.status_code == 422


@pytest.mark.asyncio
async def test_empty_content_returns_422() -> None:
    from oracle.main import app

    payload = {**BASE_PAYLOAD, "client_id": str(uuid.uuid4()), "content": "   "}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/v1/captures", json=payload, headers=AUTH_HEADERS)

    assert response.status_code == 422


@pytest.mark.asyncio
async def test_invalid_source_modality_returns_422() -> None:
    from oracle.main import app

    payload = {**BASE_PAYLOAD, "client_id": str(uuid.uuid4()), "source_modality": "video"}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/v1/captures", json=payload, headers=AUTH_HEADERS)

    assert response.status_code == 422


@pytest.mark.asyncio
async def test_wrong_typed_client_id_returns_422() -> None:
    from oracle.main import app

    payload = {**BASE_PAYLOAD, "client_id": "not-a-uuid"}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/v1/captures", json=payload, headers=AUTH_HEADERS)

    assert response.status_code == 422


@pytest.mark.asyncio
async def test_tz_naive_captured_at_returns_422() -> None:
    from oracle.main import app

    payload = {
        **BASE_PAYLOAD,
        "client_id": str(uuid.uuid4()),
        "captured_at": "2024-06-01T10:30:00",  # no TZ
    }
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/v1/captures", json=payload, headers=AUTH_HEADERS)

    assert response.status_code == 422


# ---------------------------------------------------------------------------
# Auth — smoke check the dependency is applied
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_missing_auth_returns_401() -> None:
    from oracle.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post(
            "/v1/captures", json={**BASE_PAYLOAD, "client_id": str(uuid.uuid4())}
        )

    assert response.status_code == 401


@pytest.mark.asyncio
async def test_wrong_token_returns_401() -> None:
    from oracle.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post(
            "/v1/captures",
            json={**BASE_PAYLOAD, "client_id": str(uuid.uuid4())},
            headers={"Authorization": "Bearer definitely-wrong"},
        )

    assert response.status_code == 401
