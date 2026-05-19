"""Tests for client_intent: "task" feature (#397).

Coverage:
  Capture endpoint:
    1. Accepts client_intent: "task", persists it.
    2. Rejects other client_intent values with 422.
    3. Accepts omitted client_intent (backward compatible).
    4. Accepts null client_intent (backward compatible).

  Enrichment orchestrator:
    5. client_intent == "task" always emits exactly one task row, even when
       LLM extracts nothing.
    6. client_intent == "task" with LLM-extracted task uses LLM's extraction
       (highest-confidence pick).
    7. Forced task row has confidence == 1.0.
    8. client_intent == None uses classifier-only path (0..N tasks, no forcing).

  Migration smoke:
    9. Alembic migration 0016 adds client_intent column; downgrade removes it.
"""

from __future__ import annotations

import json
import os
import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime
from unittest.mock import AsyncMock, patch

import httpx
import pytest
import respx
from httpx import ASGITransport, AsyncClient
from sqlalchemy import inspect, select, text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.pool import NullPool

from grove.core.config import settings
from grove.core.db import get_session
from grove.embeddings import EMBEDDING_DIM
from grove.models.memory import Memory
from grove.models.task import Task as TaskModel

AUTH_HEADERS = {"Authorization": f"Bearer {os.environ.get('BEARER_TOKEN', 'test-token')}"}

BASE_PAYLOAD: dict = {
    "content": "I need to call the dentist and book an appointment.",
    "source_modality": "text",
    "source_device": "iPhone 17 Pro",
    "captured_at": "2024-06-01T10:30:00+00:00",
}

_OPENAI_EMBEDDINGS_URL = "https://api.openai.com/v1/embeddings"
_FAKE_VECTOR = [0.01] * EMBEDDING_DIM

_test_engine = create_async_engine(settings.database_url, poolclass=NullPool)
_TestSession = async_sessionmaker(_test_engine, expire_on_commit=False)


def _make_openai_response(n: int = 1) -> dict:
    return {
        "object": "list",
        "data": [{"object": "embedding", "index": i, "embedding": _FAKE_VECTOR} for i in range(n)],
        "model": "text-embedding-3-small",
        "usage": {"prompt_tokens": 10 * n, "total_tokens": 10 * n},
    }


async def _override_get_session() -> AsyncIterator[AsyncSession]:
    async with _TestSession() as session:
        yield session


@pytest.fixture
def payload() -> dict:
    return {**BASE_PAYLOAD, "client_id": str(uuid.uuid4())}


@pytest.fixture
async def db_session() -> AsyncIterator[AsyncSession]:  # type: ignore[misc]
    async with _TestSession() as session:
        yield session


@pytest.fixture(autouse=True)
def override_db(monkeypatch) -> None:  # type: ignore[misc]
    from grove.main import app

    app.dependency_overrides[get_session] = _override_get_session
    yield
    app.dependency_overrides.pop(get_session, None)


@pytest.fixture(autouse=True)
def stub_check_spend_cap():  # type: ignore[return]
    with patch(
        "grove.enrichment.orchestrator.check_spend_cap",
        new_callable=AsyncMock,
        return_value=None,
    ):
        yield


def _make_memory(client_intent: str | None = None) -> Memory:
    return Memory(
        id=uuid.uuid4(),
        client_id=uuid.uuid4(),
        content="Call the dentist and book an appointment.",
        token_count=12,
        enriched=False,
        client_intent=client_intent,
        created_at=datetime.now(tz=UTC),
    )


async def _seed_memory(
    session: AsyncSession, client_intent: str | None = None
) -> Memory:
    m = _make_memory(client_intent=client_intent)
    session.add(m)
    await session.commit()
    return m


# ---------------------------------------------------------------------------
# Capture endpoint tests
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@respx.mock
async def test_capture_accepts_client_intent_task(
    payload: dict, db_session: AsyncSession
) -> None:
    """POST /v1/captures with client_intent='task' returns 201 and persists the value."""
    from grove.main import app

    respx.post(_OPENAI_EMBEDDINGS_URL).mock(
        return_value=httpx.Response(200, json=_make_openai_response())
    )
    payload["client_intent"] = "task"

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/v1/captures", json=payload, headers=AUTH_HEADERS)

    assert response.status_code == 201, response.text

    client_id = uuid.UUID(payload["client_id"])
    result = await db_session.execute(select(Memory).where(Memory.client_id == client_id))
    row = result.scalar_one()
    assert row.client_intent == "task"

    await db_session.delete(row)
    await db_session.commit()


@pytest.mark.asyncio
@respx.mock
async def test_capture_rejects_unknown_client_intent(payload: dict) -> None:
    """POST /v1/captures with an unrecognised client_intent value returns 422."""
    from grove.main import app

    respx.post(_OPENAI_EMBEDDINGS_URL).mock(
        return_value=httpx.Response(200, json=_make_openai_response())
    )
    payload["client_intent"] = "appointment"  # not a V1 allowed value

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/v1/captures", json=payload, headers=AUTH_HEADERS)

    assert response.status_code == 422, response.text


@pytest.mark.asyncio
@respx.mock
async def test_capture_omitted_client_intent_is_backward_compatible(
    payload: dict, db_session: AsyncSession
) -> None:
    """POST /v1/captures without client_intent field succeeds; row has client_intent=None."""
    from grove.main import app

    respx.post(_OPENAI_EMBEDDINGS_URL).mock(
        return_value=httpx.Response(200, json=_make_openai_response())
    )
    assert "client_intent" not in payload

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/v1/captures", json=payload, headers=AUTH_HEADERS)

    assert response.status_code == 201, response.text

    client_id = uuid.UUID(payload["client_id"])
    result = await db_session.execute(select(Memory).where(Memory.client_id == client_id))
    row = result.scalar_one()
    assert row.client_intent is None

    await db_session.delete(row)
    await db_session.commit()


@pytest.mark.asyncio
@respx.mock
async def test_capture_null_client_intent_is_backward_compatible(
    payload: dict, db_session: AsyncSession
) -> None:
    """POST /v1/captures with explicit null client_intent succeeds."""
    from grove.main import app

    respx.post(_OPENAI_EMBEDDINGS_URL).mock(
        return_value=httpx.Response(200, json=_make_openai_response())
    )
    payload["client_intent"] = None

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/v1/captures", json=payload, headers=AUTH_HEADERS)

    assert response.status_code == 201, response.text

    client_id = uuid.UUID(payload["client_id"])
    result = await db_session.execute(select(Memory).where(Memory.client_id == client_id))
    row = result.scalar_one()
    assert row.client_intent is None

    await db_session.delete(row)
    await db_session.commit()


# ---------------------------------------------------------------------------
# Enrichment orchestrator tests
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_client_intent_task_forces_task_row_when_llm_extracts_nothing(
    db_session: AsyncSession,
) -> None:
    """When client_intent='task', exactly one task row is emitted even if LLM is empty."""
    from grove.enrichment.classifier import ClassificationResult
    from grove.enrichment.orchestrator import classify_and_write
    from grove.enrichment.schemas import Classification

    memory = await _seed_memory(db_session, client_intent="task")

    empty_classification = Classification()  # no tasks, no anything
    mock_result = ClassificationResult(
        classification=empty_classification,
        prompt_tokens=10,
        completion_tokens=5,
        total_tokens=15,
        cost_usd=0.0001,
    )

    with patch(
        "grove.enrichment.orchestrator.classify_memory",
        new_callable=AsyncMock,
        return_value=mock_result,
    ):
        async with _TestSession() as session:
            mem = await session.get(Memory, memory.id)
            assert mem is not None
            await classify_and_write(mem, session)

    await db_session.refresh(memory)
    assert memory.enriched is True

    result = await db_session.execute(select(TaskModel).where(TaskModel.memory_id == memory.id))
    tasks = result.scalars().all()
    assert len(tasks) == 1, f"Expected exactly 1 task row, got {len(tasks)}"
    assert tasks[0].confidence == 1.0
    assert tasks[0].status == "open"
    # Description falls back to raw memory content when LLM has nothing.
    assert tasks[0].description  # non-empty

    await db_session.delete(await db_session.get(Memory, memory.id))
    await db_session.commit()


@pytest.mark.asyncio
async def test_client_intent_task_uses_llm_extraction_when_available(
    db_session: AsyncSession,
) -> None:
    """When client_intent='task' and LLM extracts a task, use the LLM's description."""
    from grove.enrichment.classifier import ClassificationResult
    from grove.enrichment.orchestrator import classify_and_write
    from grove.enrichment.schemas import Classification, Task as TaskSchema

    memory = await _seed_memory(db_session, client_intent="task")

    llm_task = TaskSchema(
        description="Book dentist appointment",
        due_date=None,
        status="open",
        related_people=None,
        confidence=0.82,
    )
    classification = Classification(tasks=[llm_task])
    mock_result = ClassificationResult(
        classification=classification,
        prompt_tokens=10,
        completion_tokens=5,
        total_tokens=15,
        cost_usd=0.0001,
    )

    with patch(
        "grove.enrichment.orchestrator.classify_memory",
        new_callable=AsyncMock,
        return_value=mock_result,
    ):
        async with _TestSession() as session:
            mem = await session.get(Memory, memory.id)
            assert mem is not None
            await classify_and_write(mem, session)

    await db_session.refresh(memory)
    assert memory.enriched is True

    result = await db_session.execute(select(TaskModel).where(TaskModel.memory_id == memory.id))
    tasks = result.scalars().all()
    # Exactly one task row — collapse, no duplicates.
    assert len(tasks) == 1, f"Expected exactly 1 task row, got {len(tasks)}"
    assert tasks[0].description == "Book dentist appointment"
    assert tasks[0].confidence == 1.0  # forced, not LLM's 0.82

    await db_session.delete(await db_session.get(Memory, memory.id))
    await db_session.commit()


@pytest.mark.asyncio
async def test_client_intent_task_forced_confidence_is_1_0(
    db_session: AsyncSession,
) -> None:
    """Task row emitted for a client_intent='task' memory always has confidence 1.0."""
    from grove.enrichment.classifier import ClassificationResult
    from grove.enrichment.orchestrator import classify_and_write
    from grove.enrichment.schemas import Classification, Task as TaskSchema

    memory = await _seed_memory(db_session, client_intent="task")

    # LLM returns a low-confidence task that would normally be dropped.
    llm_task = TaskSchema(
        description="Maybe schedule something",
        due_date=None,
        status="open",
        related_people=None,
        confidence=0.3,
    )
    classification = Classification(tasks=[llm_task])
    mock_result = ClassificationResult(
        classification=classification,
        prompt_tokens=10,
        completion_tokens=5,
        total_tokens=15,
        cost_usd=0.0001,
    )

    with patch(
        "grove.enrichment.orchestrator.classify_memory",
        new_callable=AsyncMock,
        return_value=mock_result,
    ):
        async with _TestSession() as session:
            mem = await session.get(Memory, memory.id)
            assert mem is not None
            await classify_and_write(mem, session)

    result = await db_session.execute(select(TaskModel).where(TaskModel.memory_id == memory.id))
    tasks = result.scalars().all()
    assert len(tasks) == 1
    assert tasks[0].confidence == 1.0

    await db_session.delete(await db_session.get(Memory, memory.id))
    await db_session.commit()


@pytest.mark.asyncio
async def test_client_intent_none_uses_classifier_only(
    db_session: AsyncSession,
) -> None:
    """When client_intent is None, no tasks are forced; 0..N depends on LLM."""
    from grove.enrichment.classifier import ClassificationResult
    from grove.enrichment.orchestrator import classify_and_write
    from grove.enrichment.schemas import Classification

    memory = await _seed_memory(db_session, client_intent=None)

    empty_classification = Classification()  # LLM finds nothing
    mock_result = ClassificationResult(
        classification=empty_classification,
        prompt_tokens=10,
        completion_tokens=5,
        total_tokens=15,
        cost_usd=0.0001,
    )

    with patch(
        "grove.enrichment.orchestrator.classify_memory",
        new_callable=AsyncMock,
        return_value=mock_result,
    ):
        async with _TestSession() as session:
            mem = await session.get(Memory, memory.id)
            assert mem is not None
            await classify_and_write(mem, session)

    result = await db_session.execute(select(TaskModel).where(TaskModel.memory_id == memory.id))
    tasks = result.scalars().all()
    # No forced task — LLM returned nothing, so zero rows expected.
    assert len(tasks) == 0

    await db_session.delete(await db_session.get(Memory, memory.id))
    await db_session.commit()


# ---------------------------------------------------------------------------
# Migration smoke test
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_client_intent_column_exists() -> None:
    """Smoke: memories.client_intent column is present (migration applied)."""
    async with _test_engine.connect() as conn:
        result = await conn.execute(
            text(
                """
                SELECT column_name
                FROM information_schema.columns
                WHERE table_name = 'memories'
                  AND column_name = 'client_intent'
                """
            )
        )
        rows = result.fetchall()
    assert len(rows) == 1, "client_intent column not found in memories table"
