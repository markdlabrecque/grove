"""Tests for GET /v1/memories/{id}.

Requires a real Postgres+pgvector instance with migrations applied.
DATABASE_URL is set by conftest.py (dev) or docker-compose CI env.
"""

from __future__ import annotations

import os
import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.pool import NullPool

from grove.core.config import settings
from grove.core.db import get_session
from grove.models.appointment import Appointment
from grove.models.decision import Decision
from grove.models.memory import Memory

AUTH_HEADERS = {"Authorization": f"Bearer {os.environ.get('BEARER_TOKEN', 'test-token')}"}

_test_engine = create_async_engine(settings.database_url, poolclass=NullPool)
_TestSession = async_sessionmaker(_test_engine, expire_on_commit=False)


async def _override_get_session() -> AsyncIterator[AsyncSession]:
    async with _TestSession() as session:
        yield session


@pytest.fixture(autouse=True)
def override_db(monkeypatch) -> None:  # type: ignore[misc]
    from grove.main import app

    app.dependency_overrides[get_session] = _override_get_session
    yield
    app.dependency_overrides.pop(get_session, None)


@pytest.fixture
async def db_session() -> AsyncIterator[AsyncSession]:  # type: ignore[misc]
    async with _TestSession() as session:
        yield session


@pytest.fixture
async def persisted_memory(db_session: AsyncSession) -> AsyncIterator[Memory]:
    """Insert a bare Memory row and clean up after the test."""
    memory = Memory(
        id=uuid.uuid4(),
        client_id=uuid.uuid4(),
        content="I decided to use SQLAlchemy selectinload for eager loading.",
        source_modality="text",
        source_device="iPhone 17 Pro",
        language="en",
        captured_at=datetime(2024, 6, 1, 10, 30, 0, tzinfo=UTC),
        enriched=False,
        embedding_model="text-embedding-3-small",
    )
    db_session.add(memory)
    await db_session.commit()
    await db_session.refresh(memory)

    yield memory

    # Teardown — cascade deletes handle related rows.
    await db_session.delete(memory)
    await db_session.commit()


# ---------------------------------------------------------------------------
# 404 — unknown UUID
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_unknown_uuid_returns_404() -> None:
    from grove.main import app

    random_id = uuid.uuid4()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get(f"/v1/memories/{random_id}", headers=AUTH_HEADERS)

    assert response.status_code == 404
    assert response.json()["detail"] == "memory not found"


# ---------------------------------------------------------------------------
# 422 — non-UUID path param
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_non_uuid_path_param_returns_422() -> None:
    from grove.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/v1/memories/not-a-uuid", headers=AUTH_HEADERS)

    assert response.status_code == 422


# ---------------------------------------------------------------------------
# 401 — missing auth (smoke)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_missing_auth_returns_401() -> None:
    from grove.main import app

    random_id = uuid.uuid4()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get(f"/v1/memories/{random_id}")

    assert response.status_code == 401


# ---------------------------------------------------------------------------
# Happy path — memory with chunks + decision + appointment
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_happy_path_returns_full_memory(
    persisted_memory: Memory, db_session: AsyncSession
) -> None:
    from grove.main import app

    # Add a decision.
    decision = Decision(
        id=uuid.uuid4(),
        memory_id=persisted_memory.id,
        decision_maker="Mark",
        context="Side project scope",
        chosen_option="Keep going",
        confidence=0.9,
        enrichment_version=1,
    )
    # Add an appointment.
    appointment = Appointment(
        id=uuid.uuid4(),
        memory_id=persisted_memory.id,
        title="Weekly sync",
        starts_at=datetime(2024, 6, 5, 9, 0, 0, tzinfo=UTC),
        confidence=0.85,
        enrichment_version=1,
    )
    db_session.add_all([decision, appointment])
    await db_session.commit()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get(f"/v1/memories/{persisted_memory.id}", headers=AUTH_HEADERS)

    assert response.status_code == 200
    body = response.json()

    # Memory fields.
    assert body["id"] == str(persisted_memory.id)
    assert body["content"] == persisted_memory.content
    assert body["enriched"] is False
    assert "embedding" not in body

    # Chunks — empty for this memory.
    assert body["chunks"] == []
    assert "embedding" not in (body["chunks"][0] if body["chunks"] else {})

    # Decisions.
    assert len(body["decisions"]) == 1
    d = body["decisions"][0]
    assert d["decision_maker"] == "Mark"
    assert d["chosen_option"] == "Keep going"
    assert d["memory_id"] == str(persisted_memory.id)

    # Appointments.
    assert len(body["appointments"]) == 1
    a = body["appointments"][0]
    assert a["title"] == "Weekly sync"
    assert a["memory_id"] == str(persisted_memory.id)

    # Specialized rows that were NOT inserted should be empty lists.
    assert body["people_interactions"] == []
    assert body["tasks"] == []


# ---------------------------------------------------------------------------
# Specialized rows grouped correctly — no leakage between types
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_specialized_rows_grouped_correctly(
    persisted_memory: Memory, db_session: AsyncSession
) -> None:
    from grove.main import app

    decision = Decision(
        id=uuid.uuid4(),
        memory_id=persisted_memory.id,
        chosen_option="option A",
        confidence=0.7,
        enrichment_version=1,
    )
    db_session.add(decision)
    await db_session.commit()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get(f"/v1/memories/{persisted_memory.id}", headers=AUTH_HEADERS)

    assert response.status_code == 200
    body = response.json()

    # Decision appears only under decisions, not under other keys.
    assert len(body["decisions"]) == 1
    assert body["appointments"] == []
    assert body["people_interactions"] == []
    assert body["tasks"] == []

    # The decision ID must not appear anywhere under the other lists.
    decision_id = str(decision.id)
    for key in ("appointments", "people_interactions", "tasks"):
        for row in body[key]:
            assert row["id"] != decision_id
