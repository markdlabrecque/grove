"""Tests for DELETE /v1/tasks/{id}.

R1.3: 204 on successful delete.
R1.4: 404 on missing task; 404 on task not owned by authenticated user (same
      shape — single query gates both, no existence leak).
R1.6: PATCH /v1/tasks/{id} handler is removed.

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
from sqlalchemy import select
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
# R1.3 — 204 on successful delete
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_delete_task_returns_204(db_session: AsyncSession) -> None:
    """R1.3: DELETE /v1/tasks/{id} removes the row and returns 204 No Content."""
    from grove.main import app

    mem = await _make_memory(db_session, "Task to be deleted")
    task = await _make_task(db_session, mem, "Complete the report")
    task_id = task.id

    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.delete(f"/v1/tasks/{task_id}", headers=AUTH_HEADERS)

        assert response.status_code == 204
        assert response.content == b""

        # Confirm row is gone from DB.
        db_session.expire_all()
        result = await db_session.execute(select(Task).where(Task.id == task_id))
        assert result.scalar_one_or_none() is None
    finally:
        # Task may already be deleted; memory cleanup is always needed.
        result = await db_session.execute(select(Task).where(Task.id == task_id))
        leftover = result.scalar_one_or_none()
        if leftover is not None:
            await db_session.delete(leftover)
        await db_session.delete(mem)
        await db_session.commit()


# ---------------------------------------------------------------------------
# R1.4 — 404 on missing task
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_delete_missing_task_returns_404() -> None:
    """R1.4: Deleting a task that does not exist returns 404."""
    from grove.main import app

    random_id = uuid.uuid4()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.delete(f"/v1/tasks/{random_id}", headers=AUTH_HEADERS)

    assert response.status_code == 404


# ---------------------------------------------------------------------------
# R1.4 — 404 on delete of another user's task (no existence leak)
#
# The system is single-tenant today — one bearer token, all tasks belong to
# that token. We simulate "not owned" by inserting a task row with a different
# bearer token in scope: since there is no per-user row scoping yet, we verify
# the contract by expecting 404 on a task that was soft-deleted or does not
# exist. A future multi-tenant refactor will add user_id FK scoping; this test
# codifies the 404-either-way shape so the contract survives that migration.
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_delete_already_deleted_task_returns_404(db_session: AsyncSession) -> None:
    """R1.4: Deleting an already-deleted task returns 404 (idempotent safety)."""
    from grove.main import app

    mem = await _make_memory(db_session, "Already-gone task memory")
    task = await _make_task(db_session, mem, "Gone task")
    task_id = task.id

    # Delete the task directly in DB to simulate "not owned / already gone."
    await db_session.delete(task)
    await db_session.commit()

    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.delete(f"/v1/tasks/{task_id}", headers=AUTH_HEADERS)

        assert response.status_code == 404
    finally:
        await db_session.delete(mem)
        await db_session.commit()


# ---------------------------------------------------------------------------
# Auth — 401 on missing bearer token
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_delete_task_no_auth_returns_401() -> None:
    """Auth required: missing bearer token returns 401 before any DB lookup."""
    from grove.main import app

    random_id = uuid.uuid4()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.delete(f"/v1/tasks/{random_id}")

    assert response.status_code == 401


# ---------------------------------------------------------------------------
# R1.6 — PATCH /v1/tasks/{id} handler is removed
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_patch_task_handler_removed_returns_405_or_404() -> None:
    """R1.6: PATCH /v1/tasks/{id} is no longer a registered route.

    FastAPI returns 405 Method Not Allowed when the path exists but the method
    is not registered, or 404 if the path prefix is gone entirely. Either is
    acceptable — what is NOT acceptable is 200 or 422.
    """
    from grove.main import app

    random_id = uuid.uuid4()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.patch(
            f"/v1/tasks/{random_id}",
            json={"eventkit_identifier": "some-id"},
            headers=AUTH_HEADERS,
        )

    assert response.status_code in {404, 405}
