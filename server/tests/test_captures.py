"""Tests for POST /v1/captures.

Requires a real Postgres+pgvector instance with migrations applied.
DATABASE_URL is set by conftest.py (dev) or docker-compose CI env.

The OpenAI embedding API is mocked at the HTTP boundary with respx so no
real API key or network access is needed.
"""

from __future__ import annotations

import json
import os
import uuid
from collections.abc import AsyncIterator

import httpx
import pytest
import respx
from httpx import ASGITransport, AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.pool import NullPool

from grove.core.config import settings
from grove.core.db import get_session
from grove.embeddings import EMBEDDING_DIM
from grove.embeddings.tokenizer import count_tokens
from grove.models.memory import Memory, MemoryChunk

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

_OPENAI_EMBEDDINGS_URL = "https://api.openai.com/v1/embeddings"
_FAKE_VECTOR = [0.01] * EMBEDDING_DIM


def _make_openai_response(n: int) -> dict:
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
    from grove.main import app

    app.dependency_overrides[get_session] = _override_get_session
    yield
    app.dependency_overrides.pop(get_session, None)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _long_content(target_tokens: int = 600) -> str:
    """Return content that tokenises to roughly target_tokens (>500 threshold)."""
    sentence = "The quick brown fox jumps over the lazy dog. "
    # Build up until we exceed target_tokens.
    text = ""
    while count_tokens(text) < target_tokens:
        text += sentence
    return text.strip()


# ---------------------------------------------------------------------------
# Short capture (<=500 tokens): whole-embedding path
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@respx.mock
async def test_happy_path_creates_memory(payload: dict, db_session: AsyncSession) -> None:
    from grove.main import app

    respx.post(_OPENAI_EMBEDDINGS_URL).mock(
        return_value=httpx.Response(200, json=_make_openai_response(1))
    )

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/v1/captures", json=payload, headers=AUTH_HEADERS)

    assert response.status_code == 201
    body = response.json()
    assert body["enriched"] is False
    assert body["client_id"] == payload["client_id"]
    assert "id" in body
    assert "captured_at" in body

    client_id = uuid.UUID(payload["client_id"])
    result = await db_session.execute(select(Memory).where(Memory.client_id == client_id))
    row = result.scalar_one()
    assert row.content == payload["content"]
    assert row.source_modality == payload["source_modality"]
    assert row.source_device == payload["source_device"]
    assert row.language == "en"
    assert row.enriched is False
    assert row.embedding_model == "text-embedding-3-small"
    # Short content: embedding stored on the memory row directly.
    assert row.embedding is not None
    assert len(row.embedding) == EMBEDDING_DIM
    # token_count must be stamped (#33).
    assert row.token_count is not None
    assert row.token_count > 0
    # No chunks for short content.
    chunks_result = await db_session.execute(
        select(MemoryChunk).where(MemoryChunk.memory_id == row.id)
    )
    assert chunks_result.scalars().all() == []

    await db_session.delete(row)
    await db_session.commit()


@pytest.mark.asyncio
@respx.mock
async def test_happy_path_with_explicit_language(payload: dict, db_session: AsyncSession) -> None:
    from grove.main import app

    respx.post(_OPENAI_EMBEDDINGS_URL).mock(
        return_value=httpx.Response(200, json=_make_openai_response(1))
    )

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


@pytest.mark.asyncio
@respx.mock
async def test_embedding_model_from_provider_not_sentinel(
    payload: dict, db_session: AsyncSession
) -> None:
    """embedding_model is taken from provider.name, not a hardcoded sentinel (#38)."""
    from grove.main import app

    respx.post(_OPENAI_EMBEDDINGS_URL).mock(
        return_value=httpx.Response(200, json=_make_openai_response(1))
    )

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/v1/captures", json=payload, headers=AUTH_HEADERS)

    assert response.status_code == 201

    client_id = uuid.UUID(payload["client_id"])
    result = await db_session.execute(select(Memory).where(Memory.client_id == client_id))
    row = result.scalar_one()
    # The provider's name property (not a hardcoded constant) drove the value.
    from grove.embeddings import get_embedding_provider

    assert row.embedding_model == get_embedding_provider().name

    await db_session.delete(row)
    await db_session.commit()


# ---------------------------------------------------------------------------
# Long capture (>500 tokens): chunked path
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@respx.mock
async def test_long_capture_uses_chunks(payload: dict, db_session: AsyncSession) -> None:
    from grove.main import app

    long_content = _long_content(target_tokens=700)
    assert count_tokens(long_content) > 500

    payload["content"] = long_content

    # We don't know exactly how many chunks the chunker will produce, so mock
    # generously — respx will return the same response regardless of body.
    embed_route = respx.post(_OPENAI_EMBEDDINGS_URL).mock(
        side_effect=lambda req: httpx.Response(
            200,
            json=_make_openai_response(len(json.loads(req.content)["input"])),
        )
    )

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/v1/captures", json=payload, headers=AUTH_HEADERS)

    assert response.status_code == 201

    client_id = uuid.UUID(payload["client_id"])
    result = await db_session.execute(select(Memory).where(Memory.client_id == client_id))
    row = result.scalar_one()

    # Long content: memories.embedding must be NULL.
    assert row.embedding is None
    # token_count is stamped (#33).
    assert row.token_count is not None
    assert row.token_count > 500

    # Multiple chunk rows with sequential chunk_index values.
    chunks_result = await db_session.execute(
        select(MemoryChunk).where(MemoryChunk.memory_id == row.id).order_by(MemoryChunk.chunk_index)
    )
    chunks = chunks_result.scalars().all()
    assert len(chunks) >= 2
    for expected_idx, ch in enumerate(chunks):
        assert ch.chunk_index == expected_idx
        assert ch.embedding is not None
        assert len(ch.embedding) == EMBEDDING_DIM

    # embed_batch was called exactly once (batch call for all chunks).
    assert embed_route.call_count == 1

    # Cleanup cascades to chunks via FK.
    await db_session.delete(row)
    await db_session.commit()


# ---------------------------------------------------------------------------
# Provider failure: rollback — no rows in DB
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@respx.mock
async def test_provider_failure_rolls_back(payload: dict, db_session: AsyncSession) -> None:
    from grove.main import app

    respx.post(_OPENAI_EMBEDDINGS_URL).mock(
        return_value=httpx.Response(500, json={"error": {"message": "internal server error"}})
    )

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/v1/captures", json=payload, headers=AUTH_HEADERS)

    # Should return 5xx — the OpenAI error propagates.
    assert response.status_code >= 500

    # No memory row must exist.
    client_id = uuid.UUID(payload["client_id"])
    result = await db_session.execute(select(Memory).where(Memory.client_id == client_id))
    assert result.scalar_one_or_none() is None


# ---------------------------------------------------------------------------
# Idempotency: duplicate client_id returns 200, embed called exactly once
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@respx.mock
async def test_idempotent_second_post_returns_200_with_same_id(
    payload: dict, db_session: AsyncSession
) -> None:
    from grove.main import app

    embed_route = respx.post(_OPENAI_EMBEDDINGS_URL).mock(
        return_value=httpx.Response(200, json=_make_openai_response(1))
    )

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

    # The embedding API was called exactly once across both POSTs (#24 idempotency).
    assert embed_route.call_count == 1

    await db_session.delete(rows[0])
    await db_session.commit()


# ---------------------------------------------------------------------------
# Validation — 422 cases (no embed calls needed)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_missing_required_field_returns_422() -> None:
    from grove.main import app

    incomplete = {k: v for k, v in BASE_PAYLOAD.items() if k != "content"}
    incomplete["client_id"] = str(uuid.uuid4())
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/v1/captures", json=incomplete, headers=AUTH_HEADERS)

    assert response.status_code == 422


@pytest.mark.asyncio
async def test_empty_content_returns_422() -> None:
    from grove.main import app

    payload = {**BASE_PAYLOAD, "client_id": str(uuid.uuid4()), "content": "   "}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/v1/captures", json=payload, headers=AUTH_HEADERS)

    assert response.status_code == 422


@pytest.mark.asyncio
async def test_invalid_source_modality_returns_422() -> None:
    from grove.main import app

    payload = {**BASE_PAYLOAD, "client_id": str(uuid.uuid4()), "source_modality": "video"}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/v1/captures", json=payload, headers=AUTH_HEADERS)

    assert response.status_code == 422


@pytest.mark.asyncio
async def test_wrong_typed_client_id_returns_422() -> None:
    from grove.main import app

    payload = {**BASE_PAYLOAD, "client_id": "not-a-uuid"}
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/v1/captures", json=payload, headers=AUTH_HEADERS)

    assert response.status_code == 422


@pytest.mark.asyncio
async def test_tz_naive_captured_at_returns_422() -> None:
    from grove.main import app

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
    from grove.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post(
            "/v1/captures", json={**BASE_PAYLOAD, "client_id": str(uuid.uuid4())}
        )

    assert response.status_code == 401


@pytest.mark.asyncio
async def test_wrong_token_returns_401() -> None:
    from grove.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post(
            "/v1/captures",
            json={**BASE_PAYLOAD, "client_id": str(uuid.uuid4())},
            headers={"Authorization": "Bearer definitely-wrong"},
        )

    assert response.status_code == 401


# ---------------------------------------------------------------------------
# Regression #32: idempotent path with captured_at IS NULL must not raise
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_idempotent_null_captured_at_returns_200(db_session: AsyncSession) -> None:
    """Pre-0010 row with captured_at=NULL must not cause a Pydantic error on the
    idempotent response path (CaptureResponse.captured_at is now datetime | None).
    """
    from grove.main import app

    client_id = uuid.uuid4()
    row = Memory(
        id=uuid.uuid4(),
        client_id=client_id,
        content="legacy memory without captured_at",
        source_modality="text",
        source_device="test-device",
        language="en",
        enriched=False,
        # captured_at intentionally omitted — simulates a pre-migration row
    )
    db_session.add(row)
    await db_session.commit()

    payload = {
        **BASE_PAYLOAD,
        "client_id": str(client_id),
    }

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/v1/captures", json=payload, headers=AUTH_HEADERS)

    assert response.status_code == 200
    body = response.json()
    assert body["id"] == str(row.id)
    assert body["captured_at"] is None

    await db_session.delete(row)
    await db_session.commit()


# ---------------------------------------------------------------------------
# client_intent='task': capture-time task row insertion (#474)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@respx.mock
async def test_capture_with_task_intent_creates_task_row(
    payload: dict, db_session: AsyncSession
) -> None:
    """POST /v1/captures with client_intent='task' inserts a tasks row immediately.

    The row must be visible in the DB within the same request cycle, before any
    enrichment worker runs.  Confidence is 1.0, status is 'open', due_date and
    related_people are null, description matches the submitted content.
    """
    from grove.main import app
    from grove.models.task import Task

    respx.post(_OPENAI_EMBEDDINGS_URL).mock(
        return_value=httpx.Response(200, json=_make_openai_response(1))
    )

    payload["client_intent"] = "task"

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/v1/captures", json=payload, headers=AUTH_HEADERS)

    assert response.status_code == 201, response.text
    memory_id = uuid.UUID(response.json()["id"])

    result = await db_session.execute(select(Task).where(Task.memory_id == memory_id))
    tasks = result.scalars().all()

    assert len(tasks) == 1, f"Expected exactly 1 task row at capture time, got {len(tasks)}"
    task = tasks[0]
    assert task.description == payload["content"]
    assert task.status == "open"
    assert task.confidence == 1.0
    assert task.due_date is None
    assert task.related_people is None
    assert task.enrichment_version is None  # sentinel: not yet enriched by the worker

    # Cleanup — cascade removes the task row via FK.
    client_id = uuid.UUID(payload["client_id"])
    mem_result = await db_session.execute(select(Memory).where(Memory.client_id == client_id))
    mem = mem_result.scalar_one()
    await db_session.delete(mem)
    await db_session.commit()
