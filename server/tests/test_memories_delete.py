"""Tests for DELETE /v1/memories/{id}.

Requires a real Postgres+pgvector instance with migrations applied.
DATABASE_URL is set by conftest.py (dev) or docker-compose CI env.

Cascade behaviour:
- memory_chunks, decisions, people_interactions, appointments are
  removed via SQLAlchemy ORM cascade ("all, delete-orphan") which triggers
  the DB-level ON DELETE CASCADE FKs.
- query_logs.returned_memory_ids is an ARRAY(UUID) with no FK constraint —
  by design (PRD §6.6). Query log rows survive memory deletion; the array
  retains the (now-stale) UUID unchanged. No NULL-scrubbing is applied.
"""

from __future__ import annotations

import os
import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.pool import NullPool

from grove.core.config import settings
from grove.core.db import get_session
from grove.models.appointment import Appointment
from grove.models.decision import Decision
from grove.models.memory import Memory, MemoryChunk
from grove.models.people_interaction import PeopleInteraction
from grove.models.query_log import QueryLog

AUTH_HEADERS = {"Authorization": f"Bearer {os.environ.get('BEARER_TOKEN', 'test-token')}"}

_test_engine = create_async_engine(settings.database_url, poolclass=NullPool)
_TestSession = async_sessionmaker(_test_engine, expire_on_commit=False)


async def _override_get_session() -> AsyncIterator[AsyncSession]:
    async with _TestSession() as session:
        yield session


@pytest.fixture(autouse=True)
def override_db() -> AsyncIterator[None]:
    from grove.main import app

    app.dependency_overrides[get_session] = _override_get_session
    yield
    app.dependency_overrides.pop(get_session, None)


@pytest.fixture
async def db_session() -> AsyncIterator[AsyncSession]:
    async with _TestSession() as session:
        yield session


# ---------------------------------------------------------------------------
# Cascade delete — full seed: chunks + all 4 specialised tables + query_log
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_delete_cascades_to_all_related_rows(db_session: AsyncSession) -> None:
    """DELETE removes the memory, chunks, and all specialised rows.

    The query_log that referenced the deleted memory must survive, with its
    returned_memory_ids array left unchanged (stale UUID — no FK constraint).
    """
    from grove.main import app

    memory_id = uuid.uuid4()
    memory = Memory(
        id=memory_id,
        client_id=uuid.uuid4(),
        content="Meeting with Sarah to discuss project timeline.",
        source_modality="voice",
        language="en",
        captured_at=datetime(2024, 7, 1, 14, 0, 0, tzinfo=UTC),
        enriched=True,
        embedding_model="text-embedding-3-small",
    )
    db_session.add(memory)
    await db_session.flush()

    chunk = MemoryChunk(
        id=uuid.uuid4(),
        memory_id=memory_id,
        chunk_index=0,
        content="Meeting with Sarah",
        # Embedding column is NOT NULL — supply a zero vector (1536-dim).
        embedding=[0.0] * 1536,
        embedding_model="text-embedding-3-small",
    )
    decision = Decision(
        id=uuid.uuid4(),
        memory_id=memory_id,
        decision_maker="Mark",
        chosen_option="Proceed with plan A",
        confidence=0.9,
        enrichment_version=1,
    )
    interaction = PeopleInteraction(
        id=uuid.uuid4(),
        memory_id=memory_id,
        person_name="Sarah",
        confidence=0.85,
        enrichment_version=1,
    )
    appointment = Appointment(
        id=uuid.uuid4(),
        memory_id=memory_id,
        title="Project sync",
        starts_at=datetime(2024, 7, 2, 10, 0, 0, tzinfo=UTC),
        confidence=0.75,
        enrichment_version=1,
    )
    db_session.add_all([chunk, decision, interaction, appointment])
    await db_session.flush()

    # query_log references the memory via returned_memory_ids (no FK).
    query_log = QueryLog(
        id=uuid.uuid4(),
        query_text="What did I discuss with Sarah?",
        tables_searched={"vector": True},
        result_count=1,
        returned_memory_ids=[memory_id],
    )
    db_session.add(query_log)
    await db_session.commit()

    chunk_id = chunk.id
    decision_id = decision.id
    interaction_id = interaction.id
    appointment_id = appointment.id
    query_log_id = query_log.id

    # Act — DELETE via the API.
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.delete(f"/v1/memories/{memory_id}", headers=AUTH_HEADERS)

    assert response.status_code == 204
    assert response.content == b""

    # The route committed its delete in a separate session; expire the test
    # session's identity map so the next get() hits the DB.
    db_session.expire_all()

    # Assert: memory is gone.
    assert await db_session.get(Memory, memory_id) is None

    # Assert: all specialised rows are gone.
    assert await db_session.get(MemoryChunk, chunk_id) is None
    assert await db_session.get(Decision, decision_id) is None
    assert await db_session.get(PeopleInteraction, interaction_id) is None
    assert await db_session.get(Appointment, appointment_id) is None

    # Assert: query_log survives with its returned_memory_ids unchanged.
    result = await db_session.execute(select(QueryLog).where(QueryLog.id == query_log_id))
    surviving_log = result.scalar_one_or_none()
    assert surviving_log is not None
    assert memory_id in surviving_log.returned_memory_ids

    # Teardown: remove the orphaned query_log.
    await db_session.delete(surviving_log)
    await db_session.commit()


# ---------------------------------------------------------------------------
# 404 — unknown memory id
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_delete_unknown_id_returns_404() -> None:
    from grove.main import app

    random_id = uuid.uuid4()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.delete(f"/v1/memories/{random_id}", headers=AUTH_HEADERS)

    assert response.status_code == 404
    assert response.json()["detail"] == "memory not found"


# ---------------------------------------------------------------------------
# 401 — missing bearer token
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_delete_missing_auth_returns_401() -> None:
    from grove.main import app

    random_id = uuid.uuid4()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.delete(f"/v1/memories/{random_id}")

    assert response.status_code == 401
