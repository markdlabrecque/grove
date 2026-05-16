"""Tests for RAG synthesis on POST /v1/queries — ticket #170.

Covers:
  - Happy path: synthesis returns answer + sources, synthesis_* columns populated.
  - Provider failure: returns null answer + sources, synthesis_* columns NULL.
  - Cost logging: stamped synthesis_cost readable back from query_logs.
  - No-API-key skip: synthesis silently skipped, answer=None, no OpenRouter call.

The OpenAI embedding API and OpenRouter synthesis API are both mocked at the
HTTP boundary with respx — no live calls.

DB setup mirrors test_queries.py: real Postgres + pgvector, shared dev DB,
each test cleans up its own rows.
"""

from __future__ import annotations

import os
import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime

import httpx
import pytest
import respx
from httpx import ASGITransport, AsyncClient
from sqlalchemy import delete
from sqlalchemy import select as sa_select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.pool import NullPool

from grove.core.config import settings
from grove.embeddings import EMBEDDING_DIM
from grove.models.memory import Memory
from grove.models.query_log import QueryLog

AUTH_HEADERS = {"Authorization": f"Bearer {os.environ.get('BEARER_TOKEN', 'test-token')}"}

_test_engine = create_async_engine(settings.database_url, poolclass=NullPool)
_TestSession = async_sessionmaker(_test_engine, expire_on_commit=False)

_OPENAI_EMBEDDINGS_URL = "https://api.openai.com/v1/embeddings"
_OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"

_QUERY_VEC = [1.0] + [0.0] * (EMBEDDING_DIM - 1)


def _make_openai_response(vec: list[float]) -> dict:
    return {
        "object": "list",
        "data": [{"object": "embedding", "index": 0, "embedding": vec}],
        "model": "text-embedding-3-small",
        "usage": {"prompt_tokens": 5, "total_tokens": 5},
    }


def _make_openrouter_response(
    answer: str, prompt_tokens: int = 42, completion_tokens: int = 18
) -> dict:
    """Minimal OpenRouter chat-completion response."""
    return {
        "id": "gen-test",
        "object": "chat.completion",
        "model": "openai/gpt-4o-mini",
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": answer},
                "finish_reason": "stop",
            }
        ],
        "usage": {
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "total_tokens": prompt_tokens + completion_tokens,
        },
    }


async def _override_get_session() -> AsyncIterator[AsyncSession]:
    async with _TestSession() as session:
        yield session


def _override_get_log_session_factory() -> async_sessionmaker[AsyncSession]:
    return _TestSession


@pytest.fixture(autouse=True)
def override_db_and_api_key(monkeypatch) -> None:  # type: ignore[misc]
    from pydantic import SecretStr

    from grove.api.queries import get_log_session_factory
    from grove.core.config import settings
    from grove.core.db import get_session
    from grove.main import app

    app.dependency_overrides[get_session] = _override_get_session
    app.dependency_overrides[get_log_session_factory] = _override_get_log_session_factory
    # Ensure synthesis is attempted even when OPENROUTER_API_KEY is unset or
    # empty in the test environment. The HTTP call is intercepted by respx.
    monkeypatch.setattr(settings, "openrouter_api_key", SecretStr("test-stub-key"))
    yield
    app.dependency_overrides.pop(get_session, None)
    app.dependency_overrides.pop(get_log_session_factory, None)


@pytest.fixture
async def db_session() -> AsyncIterator[AsyncSession]:  # type: ignore[misc]
    async with _TestSession() as session:
        yield session


async def _seed_whole_memory(
    session: AsyncSession,
    embedding: list[float],
    content: str = "A short memory for testing.",
    memory_id: uuid.UUID | None = None,
) -> uuid.UUID:
    mid = memory_id or uuid.uuid4()
    memory = Memory(
        id=mid,
        client_id=uuid.uuid4(),
        content=content,
        source_modality="text",
        source_device="test-device",
        language="en",
        captured_at=datetime(2024, 6, 1, 10, 0, 0, tzinfo=UTC),
        enriched=False,
        embedding_model="text-embedding-3-small",
        embedding=embedding,
    )
    session.add(memory)
    await session.commit()
    return mid


async def _delete_query_logs_for_memory(session: AsyncSession, memory_id: uuid.UUID) -> None:
    from sqlalchemy import text

    await session.execute(
        text("DELETE FROM query_logs WHERE returned_memory_ids @> ARRAY[:mid]::uuid[]"),
        {"mid": str(memory_id)},
    )
    await session.commit()


async def _delete_memory(session: AsyncSession, memory_id: uuid.UUID) -> None:
    await _delete_query_logs_for_memory(session, memory_id)
    await session.execute(delete(Memory).where(Memory.id == memory_id))
    await session.commit()


# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@respx.mock
async def test_synthesis_happy_path_returns_answer_and_sources(db_session: AsyncSession) -> None:
    """Synthesis returns an answer string and sources list; response includes query_id."""
    from grove.main import app

    memory_id = await _seed_whole_memory(
        db_session,
        embedding=_QUERY_VEC,
        content="The meeting was scheduled for Tuesday at 3pm.",
    )
    try:
        respx.post(_OPENAI_EMBEDDINGS_URL).mock(
            return_value=httpx.Response(200, json=_make_openai_response(_QUERY_VEC))
        )
        respx.post(_OPENROUTER_URL).mock(
            return_value=httpx.Response(
                200,
                json=_make_openrouter_response(f"The meeting is on Tuesday at 3pm [#{memory_id}]."),
                headers={"x-openrouter-cost": "0.000021"},
            )
        )

        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.post(
                "/v1/queries",
                json={"query": "When is the meeting?", "limit": 10},
                headers=AUTH_HEADERS,
            )

        assert response.status_code == 200
        body = response.json()

        # New top-level fields.
        assert "answer" in body
        assert "sources" in body
        assert "query_id" in body

        # answer is a non-empty string on success.
        assert isinstance(body["answer"], str)
        assert len(body["answer"]) > 0

        # sources is a list of dicts with the expected keys.
        assert isinstance(body["sources"], list)
        assert len(body["sources"]) >= 1

        source = next((s for s in body["sources"] if s["memory_id"] == str(memory_id)), None)
        assert source is not None, "Seeded memory_id must appear in sources"
        # Per-source schema.
        assert "memory_id" in source
        assert "excerpt" in source
        assert "score" in source
        assert "matched_via" in source
        assert "matched_chunk_index" in source

        # query_id is a valid UUID string.
        assert uuid.UUID(body["query_id"])

        # query_token_count and latency_ms still present (backwards-compat).
        assert "query_token_count" in body
        assert "latency_ms" in body
    finally:
        await _delete_memory(db_session, memory_id)


# ---------------------------------------------------------------------------
# synthesis_* columns stamped in query_logs
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@respx.mock
async def test_synthesis_columns_stamped_in_query_log(db_session: AsyncSession) -> None:
    """synthesis_model, input_tokens, output_tokens, and cost are written to query_logs."""
    from grove.main import app

    memory_id = await _seed_whole_memory(
        db_session,
        embedding=_QUERY_VEC,
        content="Cost logging test memory.",
    )
    try:
        respx.post(_OPENAI_EMBEDDINGS_URL).mock(
            return_value=httpx.Response(200, json=_make_openai_response(_QUERY_VEC))
        )
        respx.post(_OPENROUTER_URL).mock(
            return_value=httpx.Response(
                200,
                json=_make_openrouter_response(
                    "Test answer.", prompt_tokens=55, completion_tokens=12
                ),
                headers={"x-openrouter-cost": "0.000033"},
            )
        )

        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.post(
                "/v1/queries",
                json={"query": "cost logging test", "limit": 50},
                headers=AUTH_HEADERS,
            )

        assert response.status_code == 200
        body = response.json()
        query_id = uuid.UUID(body["query_id"])

        # Reload the specific log row by query_id.
        result = await db_session.execute(sa_select(QueryLog).where(QueryLog.id == query_id))
        log_row = result.scalar_one_or_none()

        assert log_row is not None
        assert log_row.synthesis_model == settings.synthesis_model
        assert log_row.synthesis_input_tokens == 55
        assert log_row.synthesis_output_tokens == 12
        # synthesis_cost is stored as NUMERIC and returned as Decimal by SQLAlchemy.
        assert log_row.synthesis_cost is not None
        assert abs(float(log_row.synthesis_cost) - 0.000033) < 1e-8
    finally:
        await _delete_memory(db_session, memory_id)


# ---------------------------------------------------------------------------
# Synthesis provider failure — graceful degradation
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@respx.mock
async def test_synthesis_provider_failure_returns_null_answer_with_sources(
    db_session: AsyncSession,
) -> None:
    """When OpenRouter returns 5xx, answer is null and sources are still populated."""
    from grove.main import app

    memory_id = await _seed_whole_memory(
        db_session,
        embedding=_QUERY_VEC,
        content="Graceful degradation test memory.",
    )
    try:
        respx.post(_OPENAI_EMBEDDINGS_URL).mock(
            return_value=httpx.Response(200, json=_make_openai_response(_QUERY_VEC))
        )
        # Synthesis call fails with 503.
        respx.post(_OPENROUTER_URL).mock(
            return_value=httpx.Response(503, json={"error": "Service Unavailable"})
        )

        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.post(
                "/v1/queries",
                json={"query": "degradation test", "limit": 10},
                headers=AUTH_HEADERS,
            )

        assert response.status_code == 200
        body = response.json()

        # answer is null on synthesis failure.
        assert body["answer"] is None

        # sources are still populated even when synthesis fails.
        assert isinstance(body["sources"], list)
        assert len(body["sources"]) >= 1
        assert any(s["memory_id"] == str(memory_id) for s in body["sources"])

        # query_id is still present.
        assert "query_id" in body
        query_id = uuid.UUID(body["query_id"])

        # synthesis_* columns are NULL on failure (decision: leave them NULL
        # so it's clear no cost was incurred and no partial data is misleading).
        result = await db_session.execute(sa_select(QueryLog).where(QueryLog.id == query_id))
        log_row = result.scalar_one_or_none()
        assert log_row is not None
        assert log_row.synthesis_model is None
        assert log_row.synthesis_input_tokens is None
        assert log_row.synthesis_output_tokens is None
        assert log_row.synthesis_cost is None
    finally:
        await _delete_memory(db_session, memory_id)


# ---------------------------------------------------------------------------
# Empty-key skip — no OpenRouter call, warning emitted
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@respx.mock
async def test_synthesis_skipped_when_no_api_key(
    db_session: AsyncSession, monkeypatch: pytest.MonkeyPatch
) -> None:
    """When openrouter_api_key is None, synthesis is skipped silently.

    Asserts:
    - answer is None in the response (skip, not a failure).
    - sources are still populated (retrieval proceeds normally).
    - No HTTP request is made to the OpenRouter URL.
    - The warning log event synthesis_skipped_no_api_key is emitted.
    """
    import structlog.testing

    from grove.main import app

    # Override the key stub set by override_db_and_api_key to simulate absence.
    monkeypatch.setattr(settings, "openrouter_api_key", None)

    memory_id = await _seed_whole_memory(
        db_session,
        embedding=_QUERY_VEC,
        content="A memory that would be synthesised if a key were present.",
    )
    try:
        respx.post(_OPENAI_EMBEDDINGS_URL).mock(
            return_value=httpx.Response(200, json=_make_openai_response(_QUERY_VEC))
        )
        # Intentionally no mock for _OPENROUTER_URL — respx.mock will raise
        # httpx.ConnectError if a request is attempted, which would fail the test.

        with structlog.testing.capture_logs() as captured:
            async with AsyncClient(
                transport=ASGITransport(app=app), base_url="http://test"
            ) as client:
                response = await client.post(
                    "/v1/queries",
                    json={"query": "will this synthesise?", "limit": 10},
                    headers=AUTH_HEADERS,
                )

        assert response.status_code == 200
        body = response.json()

        # answer is None — skip, not a failure.
        assert body["answer"] is None

        # sources still populated — retrieval is unaffected by the missing key.
        assert isinstance(body["sources"], list)
        assert any(s["memory_id"] == str(memory_id) for s in body["sources"])

        # No HTTP request was sent to OpenRouter.
        assert not respx.calls.filter(url__regex=r"openrouter\.ai").called

        # Warning log was emitted.
        skip_events = [e for e in captured if e.get("event") == "synthesis_skipped_no_api_key"]
        assert skip_events, "Expected synthesis_skipped_no_api_key log event"
    finally:
        await _delete_memory(db_session, memory_id)
