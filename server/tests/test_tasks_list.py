"""Tests for GET /v1/tasks — unfiltered task list for authenticated user.

R1.1: Returns list[TaskSchema] for all tasks, sorted created_at DESC.
R1.2: Sorted created_at DESC; no pagination, no filter params.
R1.5: Old memory_ids / eventkit_identifiers query params are removed.

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
def override_db() -> AsyncIterator[None]:
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
) -> Task:
    task = Task(
        id=uuid.uuid4(),
        memory_id=memory.id,
        description=description,
        confidence=0.9,
        enrichment_version=1,
    )
    db_session.add(task)
    await db_session.commit()
    await db_session.refresh(task)
    return task


# ---------------------------------------------------------------------------
# R1.1 — happy path: tasks returned with correct TaskSchema shape
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_list_tasks_returns_all_tasks(db_session: AsyncSession) -> None:
    """R1.1: GET /v1/tasks returns all task rows with correct TaskSchema shape."""
    from grove.main import app

    mem_a = await _make_memory(db_session, "Buy groceries")
    mem_b = await _make_memory(db_session, "Call dentist")
    task_a = await _make_task(db_session, mem_a, "Buy milk and eggs")
    task_b = await _make_task(db_session, mem_b, "Schedule appointment")

    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.get("/v1/tasks", headers=AUTH_HEADERS)

        assert response.status_code == 200
        body = response.json()
        assert isinstance(body, list)
        returned_ids = {item["id"] for item in body}
        assert str(task_a.id) in returned_ids
        assert str(task_b.id) in returned_ids

        # Verify TaskSchema shape
        sample = next(item for item in body if item["id"] == str(task_a.id))
        assert sample["memory_id"] == str(mem_a.id)
        assert sample["description"] == "Buy milk and eggs"
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
# R1.1 — empty result: no tasks returns 200 []
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_list_tasks_empty_returns_empty_array(db_session: AsyncSession) -> None:
    """R1.1: When no tasks exist, GET /v1/tasks returns 200 with an empty array."""
    from grove.main import app

    # Use a unique memory we can track; bulk-delete guard: teardown cleans only known rows.
    mem = await _make_memory(db_session, "No-task memory sentinel")

    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.get("/v1/tasks", headers=AUTH_HEADERS)

        assert response.status_code == 200
        body = response.json()
        assert isinstance(body, list)
        # All tasks we control via this memory are zero; we don't assert global empty
        # because other tests may leave rows, but we verify our memory has no tasks.
        task_ids_for_our_memory = [item for item in body if item["memory_id"] == str(mem.id)]
        assert task_ids_for_our_memory == []
    finally:
        await db_session.delete(mem)
        await db_session.commit()


# ---------------------------------------------------------------------------
# R1.2 — sort order: created_at DESC
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_list_tasks_sorted_created_at_desc(db_session: AsyncSession) -> None:
    """R1.2: Tasks are returned sorted by created_at descending (newest first)."""
    from grove.main import app

    mem = await _make_memory(db_session, "Sort order test")
    # Insert two tasks; database server_default gives them close but distinct timestamps.
    # Insert sequentially so created_at order is deterministic.
    task_first = await _make_task(db_session, mem, "Task inserted first")
    task_second = await _make_task(db_session, mem, "Task inserted second")

    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.get("/v1/tasks", headers=AUTH_HEADERS)

        assert response.status_code == 200
        body = response.json()
        our_tasks = [item for item in body if item["memory_id"] == str(mem.id)]
        assert len(our_tasks) == 2

        # Newest (second inserted) should appear before oldest (first inserted).
        our_ids = [item["id"] for item in our_tasks]
        assert our_ids.index(str(task_second.id)) < our_ids.index(str(task_first.id))
    finally:
        await db_session.delete(task_first)
        await db_session.delete(task_second)
        await db_session.delete(mem)
        await db_session.commit()


# ---------------------------------------------------------------------------
# R1.5 — filter params removed: memory_ids no longer accepted
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_list_tasks_memory_ids_param_ignored_or_removed() -> None:
    """R1.5: memory_ids query param is no longer a supported filter; endpoint
    returns all tasks (param is unknown and ignored by FastAPI, or returns tasks
    without filtering). The old 422-on-invalid-uuid path must NOT exist."""
    from grove.main import app

    # Previously, memory_ids=not-valid returned 422. After removal, the param
    # is unknown — FastAPI ignores unknown query params, so we get 200 (not 422).
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get(
            "/v1/tasks",
            params={"memory_ids": "not-a-valid-uuid"},
            headers=AUTH_HEADERS,
        )

    # Must NOT be 422 — the memory_ids filter path is removed.
    assert response.status_code == 200


# ---------------------------------------------------------------------------
# Auth — 401 on missing bearer token
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_list_tasks_no_auth_returns_401() -> None:
    """Auth required: missing bearer token returns 401."""
    from grove.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/v1/tasks")

    assert response.status_code == 401
