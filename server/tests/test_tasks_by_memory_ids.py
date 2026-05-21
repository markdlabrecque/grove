"""Tests for GET /v1/tasks?memory_ids=... — batch lookup by memory ID.

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
BAD_AUTH_HEADERS = {"Authorization": "Bearer wrong-token"}

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
# Happy path — multiple memory IDs return their tasks
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_list_tasks_by_memory_ids_returns_tasks(db_session: AsyncSession) -> None:
    """Multiple memory_ids in query returns all matching tasks."""
    from grove.main import app

    mem_a = await _make_memory(db_session, "Buy groceries")
    mem_b = await _make_memory(db_session, "Call dentist")
    task_a = await _make_task(db_session, mem_a, "Buy milk and eggs")
    task_b = await _make_task(db_session, mem_b, "Schedule appointment")

    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.get(
                "/v1/tasks",
                params={"memory_ids": f"{mem_a.id},{mem_b.id}"},
                headers=AUTH_HEADERS,
            )

        assert response.status_code == 200
        body = response.json()
        assert isinstance(body, list)
        returned_ids = {item["id"] for item in body}
        assert str(task_a.id) in returned_ids
        assert str(task_b.id) in returned_ids
        # Verify TaskSchema shape is returned (same as PATCH endpoint)
        sample = next(item for item in body if item["id"] == str(task_a.id))
        assert sample["memory_id"] == str(mem_a.id)
        assert sample["description"] == "Buy milk and eggs"
        assert "eventkit_identifier" in sample
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


# ---------------------------------------------------------------------------
# Empty list — no memory_ids supplied returns empty array
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_list_tasks_no_memory_ids_returns_empty(db_session: AsyncSession) -> None:
    """Omitting memory_ids (empty list) returns 200 with an empty array."""
    from grove.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get(
            "/v1/tasks",
            params={"memory_ids": ""},
            headers=AUTH_HEADERS,
        )

    assert response.status_code == 200
    assert response.json() == []


# ---------------------------------------------------------------------------
# Unknown IDs — silently ignored, partial matches work
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_list_tasks_unknown_memory_id_silently_ignored(db_session: AsyncSession) -> None:
    """Unknown memory_ids are ignored; known ones are still returned."""
    from grove.main import app

    mem = await _make_memory(db_session, "Prepare slides")
    task = await _make_task(db_session, mem, "Build deck")
    unknown_id = uuid.uuid4()

    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.get(
                "/v1/tasks",
                params={"memory_ids": f"{mem.id},{unknown_id}"},
                headers=AUTH_HEADERS,
            )

        assert response.status_code == 200
        body = response.json()
        returned_ids = {item["id"] for item in body}
        assert str(task.id) in returned_ids
    finally:
        await db_session.delete(task)
        await db_session.delete(mem)
        await db_session.commit()


@pytest.mark.asyncio
async def test_list_tasks_all_unknown_memory_ids_returns_empty() -> None:
    """All-unknown memory_ids returns 200 with empty array."""
    from grove.main import app

    unknown_a = uuid.uuid4()
    unknown_b = uuid.uuid4()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get(
            "/v1/tasks",
            params={"memory_ids": f"{unknown_a},{unknown_b}"},
            headers=AUTH_HEADERS,
        )

    assert response.status_code == 200
    assert response.json() == []


# ---------------------------------------------------------------------------
# Auth failures
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_list_tasks_no_auth_returns_401() -> None:
    from grove.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get(
            "/v1/tasks",
            params={"memory_ids": str(uuid.uuid4())},
        )

    assert response.status_code == 401


@pytest.mark.asyncio
async def test_list_tasks_bad_token_returns_401() -> None:
    from grove.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get(
            "/v1/tasks",
            params={"memory_ids": str(uuid.uuid4())},
            headers=BAD_AUTH_HEADERS,
        )

    assert response.status_code == 401


# ---------------------------------------------------------------------------
# Invalid UUID — 422 with offending value in detail
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_list_tasks_invalid_uuid_returns_422() -> None:
    """A non-UUID token in memory_ids returns 422 with the offending value in the detail."""
    from grove.main import app

    valid_id = uuid.uuid4()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get(
            "/v1/tasks",
            params={"memory_ids": f"{valid_id},not-valid"},
            headers=AUTH_HEADERS,
        )

    assert response.status_code == 422
    detail = response.json()["detail"]
    assert "not-valid" in detail
