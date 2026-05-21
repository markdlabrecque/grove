"""Tests for GET /v1/tasks?eventkit_identifiers=... — batch lookup by EventKit identifier.

Identifiers are opaque strings (EKReminder.calendarItemIdentifier), NOT UUIDs.
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
from grove.models.memory import Memory
from grove.models.task import Task

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
async def db_session() -> AsyncIterator[AsyncSession]:
    async with _TestSession() as session:
        yield session


async def _make_memory(db_session: AsyncSession, content: str = "test memory") -> Memory:
    memory = Memory(
        id=uuid.uuid4(),
        client_id=uuid.uuid4(),
        content=content,
        source_modality="text",
        source_device="iPhone",
        language="en",
        captured_at=datetime(2026, 5, 1, 10, 0, 0, tzinfo=UTC),
        enriched=False,
        embedding_model="text-embedding-3-small",
    )
    db_session.add(memory)
    await db_session.commit()
    await db_session.refresh(memory)
    return memory


async def _make_task(
    db_session: AsyncSession,
    memory: Memory,
    description: str = "Do something",
    eventkit_identifier: str | None = None,
) -> Task:
    task = Task(
        id=uuid.uuid4(),
        memory_id=memory.id,
        description=description,
        confidence=0.9,
        enrichment_version=1,
        eventkit_identifier=eventkit_identifier,
    )
    db_session.add(task)
    await db_session.commit()
    await db_session.refresh(task)
    return task


# ---------------------------------------------------------------------------
# R1.1 — opaque-string identifiers: NOT UUID-validated
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_non_uuid_eventkit_identifier_not_rejected(db_session: AsyncSession) -> None:
    """R1.1: Non-UUID identifiers are accepted, not 422'd."""
    from grove.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get(
            "/v1/tasks",
            params={"eventkit_identifiers": "not-a-uuid,also-not-a-uuid"},
            headers=AUTH_HEADERS,
        )

    # Must not be 422; opaque strings are valid identifiers
    assert response.status_code == 200
    assert response.json() == []


# ---------------------------------------------------------------------------
# R1.2 — empty / whitespace / absent → 200 []
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_eventkit_identifiers_absent_returns_empty() -> None:
    """R1.2: Omitting eventkit_identifiers entirely returns 200 []."""
    from grove.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get(
            "/v1/tasks",
            headers=AUTH_HEADERS,
        )

    assert response.status_code == 200
    assert response.json() == []


@pytest.mark.asyncio
async def test_eventkit_identifiers_empty_string_returns_empty() -> None:
    """R1.2: Empty string for eventkit_identifiers returns 200 []."""
    from grove.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get(
            "/v1/tasks",
            params={"eventkit_identifiers": ""},
            headers=AUTH_HEADERS,
        )

    assert response.status_code == 200
    assert response.json() == []


@pytest.mark.asyncio
async def test_eventkit_identifiers_whitespace_returns_empty() -> None:
    """R1.2: Whitespace-only eventkit_identifiers returns 200 []."""
    from grove.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get(
            "/v1/tasks",
            params={"eventkit_identifiers": "   "},
            headers=AUTH_HEADERS,
        )

    assert response.status_code == 200
    assert response.json() == []


# ---------------------------------------------------------------------------
# R1.3 — filtered TaskSchema results; unknown identifiers silently skipped
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_list_tasks_by_eventkit_identifiers_returns_matching_tasks(
    db_session: AsyncSession,
) -> None:
    """R1.3: Known identifiers return the matching tasks with correct TaskSchema shape."""
    from grove.main import app

    mem_a = await _make_memory(db_session, "Call dentist")
    mem_b = await _make_memory(db_session, "Buy milk")
    ek_id_a = "A1B2C3D4-E5F6-7890-ABCD-EF1234567890"
    ek_id_b = "opaque-non-uuid-style-identifier-xyz"
    task_a = await _make_task(db_session, mem_a, "Schedule appointment", eventkit_identifier=ek_id_a)
    task_b = await _make_task(db_session, mem_b, "Pick up 2% milk", eventkit_identifier=ek_id_b)

    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.get(
                "/v1/tasks",
                params={"eventkit_identifiers": f"{ek_id_a},{ek_id_b}"},
                headers=AUTH_HEADERS,
            )

        assert response.status_code == 200
        body = response.json()
        assert isinstance(body, list)
        returned_ids = {item["id"] for item in body}
        assert str(task_a.id) in returned_ids
        assert str(task_b.id) in returned_ids

        # Verify full TaskSchema shape
        sample = next(item for item in body if item["id"] == str(task_a.id))
        assert sample["memory_id"] == str(mem_a.id)
        assert sample["description"] == "Schedule appointment"
        assert sample["eventkit_identifier"] == ek_id_a
        assert "eventkit_linked_at" in sample
        assert "confidence" in sample
        assert "enrichment_version" in sample
        assert "created_at" in sample
        assert "due_date" in sample
    finally:
        await db_session.delete(task_a)
        await db_session.delete(task_b)
        await db_session.delete(mem_a)
        await db_session.delete(mem_b)
        await db_session.commit()


@pytest.mark.asyncio
async def test_unknown_eventkit_identifiers_silently_skipped(db_session: AsyncSession) -> None:
    """R1.3: Unknown identifiers are silently ignored; known ones still returned."""
    from grove.main import app

    mem = await _make_memory(db_session, "Prepare presentation")
    ek_id = "known-identifier-abc"
    task = await _make_task(db_session, mem, "Build slides", eventkit_identifier=ek_id)

    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.get(
                "/v1/tasks",
                params={"eventkit_identifiers": f"{ek_id},unknown-id-xyz,another-unknown"},
                headers=AUTH_HEADERS,
            )

        assert response.status_code == 200
        body = response.json()
        returned_ids = {item["id"] for item in body}
        assert str(task.id) in returned_ids
        assert len(body) == 1
    finally:
        await db_session.delete(task)
        await db_session.delete(mem)
        await db_session.commit()


@pytest.mark.asyncio
async def test_all_unknown_eventkit_identifiers_returns_empty() -> None:
    """R1.3: All-unknown identifiers returns 200 []."""
    from grove.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get(
            "/v1/tasks",
            params={"eventkit_identifiers": "ghost-id-1,ghost-id-2"},
            headers=AUTH_HEADERS,
        )

    assert response.status_code == 200
    assert response.json() == []


# ---------------------------------------------------------------------------
# R1.4 — structured log (coverage via smoke: endpoint completes without error)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_list_tasks_by_eventkit_identifiers_logs_structured_event(
    db_session: AsyncSession,
) -> None:
    """R1.4: Endpoint completes successfully (log event emitted without error)."""
    from grove.main import app

    mem = await _make_memory(db_session, "Draft email")
    ek_id = "log-test-identifier-123"
    task = await _make_task(db_session, mem, "Write intro", eventkit_identifier=ek_id)

    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.get(
                "/v1/tasks",
                params={"eventkit_identifiers": ek_id},
                headers=AUTH_HEADERS,
            )

        assert response.status_code == 200
        assert len(response.json()) == 1
    finally:
        await db_session.delete(task)
        await db_session.delete(mem)
        await db_session.commit()


# ---------------------------------------------------------------------------
# R1.5 — combining memory_ids AND eventkit_identifiers returns 422
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_combining_memory_ids_and_eventkit_identifiers_returns_422() -> None:
    """R1.5: Passing both memory_ids and eventkit_identifiers returns 422."""
    from grove.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get(
            "/v1/tasks",
            params={
                "memory_ids": str(uuid.uuid4()),
                "eventkit_identifiers": "some-ek-id",
            },
            headers=AUTH_HEADERS,
        )

    assert response.status_code == 422
