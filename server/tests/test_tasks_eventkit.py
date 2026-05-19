"""Tests for PATCH /v1/tasks/{id} — EventKit identifier linking.

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


@pytest.fixture
async def persisted_memory(db_session: AsyncSession) -> AsyncIterator[Memory]:
    """Insert a bare Memory row and clean up after the test."""
    memory = Memory(
        id=uuid.uuid4(),
        client_id=uuid.uuid4(),
        content="Call Alice about the project deadline next Friday.",
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

    yield memory

    await db_session.delete(memory)
    await db_session.commit()


@pytest.fixture
async def unlinked_task(db_session: AsyncSession, persisted_memory: Memory) -> AsyncIterator[Task]:
    """Insert a Task row without an EventKit identifier."""
    task = Task(
        id=uuid.uuid4(),
        memory_id=persisted_memory.id,
        description="Call Alice about the project deadline",
        confidence=0.92,
        enrichment_version=1,
    )
    db_session.add(task)
    await db_session.commit()
    await db_session.refresh(task)

    yield task

    # Memory cascade handles deletion; delete task explicitly in case test
    # already deleted the memory.
    try:
        await db_session.delete(task)
        await db_session.commit()
    except Exception:
        pass


@pytest.fixture
async def linked_task(db_session: AsyncSession, persisted_memory: Memory) -> AsyncIterator[Task]:
    """Insert a Task row that already has an EventKit identifier."""
    task = Task(
        id=uuid.uuid4(),
        memory_id=persisted_memory.id,
        description="Follow up with Bob",
        confidence=0.88,
        enrichment_version=1,
        eventkit_identifier="existing-ek-id-abc123",
        eventkit_linked_at=datetime(2026, 5, 2, 9, 0, 0, tzinfo=UTC),
    )
    db_session.add(task)
    await db_session.commit()
    await db_session.refresh(task)

    yield task

    try:
        await db_session.delete(task)
        await db_session.commit()
    except Exception:
        pass


# ---------------------------------------------------------------------------
# 200 happy path — link an unlinked task
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_patch_task_links_eventkit_identifier(unlinked_task: Task) -> None:
    from grove.main import app

    ek_id = "x-apple-reminderkit://REMCDReminder/new-ek-id-xyz789"
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.patch(
            f"/v1/tasks/{unlinked_task.id}",
            json={"eventkit_identifier": ek_id},
            headers=AUTH_HEADERS,
        )

    assert response.status_code == 200
    body = response.json()
    assert body["id"] == str(unlinked_task.id)
    assert body["eventkit_identifier"] == ek_id
    assert body["eventkit_linked_at"] is not None


# ---------------------------------------------------------------------------
# 409 — already-linked task
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_patch_already_linked_task_returns_409(linked_task: Task) -> None:
    from grove.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.patch(
            f"/v1/tasks/{linked_task.id}",
            json={"eventkit_identifier": "new-id-that-should-be-rejected"},
            headers=AUTH_HEADERS,
        )

    assert response.status_code == 409
    body = response.json()
    # FastAPI wraps HTTPException detail under the "detail" key.
    # The existing identifier is nested so the iOS client can self-heal.
    assert body["detail"]["existing_identifier"] == "existing-ek-id-abc123"


# ---------------------------------------------------------------------------
# 404 — task does not exist
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_patch_unknown_task_returns_404() -> None:
    from grove.main import app

    random_id = uuid.uuid4()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.patch(
            f"/v1/tasks/{random_id}",
            json={"eventkit_identifier": "some-ek-id"},
            headers=AUTH_HEADERS,
        )

    assert response.status_code == 404


# ---------------------------------------------------------------------------
# 401 — missing / bad auth
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_patch_task_no_auth_returns_401() -> None:
    from grove.main import app

    random_id = uuid.uuid4()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.patch(
            f"/v1/tasks/{random_id}",
            json={"eventkit_identifier": "some-ek-id"},
        )

    assert response.status_code == 401


@pytest.mark.asyncio
async def test_patch_task_bad_token_returns_401() -> None:
    from grove.main import app

    random_id = uuid.uuid4()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.patch(
            f"/v1/tasks/{random_id}",
            json={"eventkit_identifier": "some-ek-id"},
            headers=BAD_AUTH_HEADERS,
        )

    assert response.status_code == 401


# ---------------------------------------------------------------------------
# 422 — missing or empty eventkit_identifier
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_patch_task_missing_field_returns_422() -> None:
    from grove.main import app

    random_id = uuid.uuid4()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.patch(
            f"/v1/tasks/{random_id}",
            json={},
            headers=AUTH_HEADERS,
        )

    assert response.status_code == 422


@pytest.mark.asyncio
async def test_patch_task_empty_string_returns_422() -> None:
    from grove.main import app

    random_id = uuid.uuid4()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.patch(
            f"/v1/tasks/{random_id}",
            json={"eventkit_identifier": ""},
            headers=AUTH_HEADERS,
        )

    assert response.status_code == 422


@pytest.mark.asyncio
async def test_patch_task_null_field_returns_422() -> None:
    from grove.main import app

    random_id = uuid.uuid4()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.patch(
            f"/v1/tasks/{random_id}",
            json={"eventkit_identifier": None},
            headers=AUTH_HEADERS,
        )

    assert response.status_code == 422
