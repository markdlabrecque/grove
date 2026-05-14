"""Tests for the intent router + hybrid retrieval — ticket #175.

Coverage:
- Unit: intent classifier output parser (happy path + malformed JSON fallback)
- Unit: each specialised-table query path with seeded rows (4 tests)
- Unit: empty-table optimization — skip + log "empty" when table has 0 rows
- Integration: specialised-matched memory surfaces even when not in top-K vector
- Integration: tables_searched populated correctly for every query
- Integration: intent_router cost stamped on query_logs

All LLM HTTP calls are mocked via respx. Embedding calls go through the same
respx mock as the other query tests. DB uses the shared dev Postgres instance
with migrations applied.
"""

from __future__ import annotations

import json
import os
import uuid
from collections.abc import AsyncIterator
from datetime import UTC, date, datetime

import httpx
import pytest
import respx
from httpx import ASGITransport, AsyncClient
from sqlalchemy import delete
from sqlalchemy import select as sa_select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.pool import NullPool

from oracle.core.config import settings
from oracle.embeddings import EMBEDDING_DIM
from oracle.models.appointment import Appointment
from oracle.models.decision import Decision
from oracle.models.memory import Memory
from oracle.models.people_interaction import PeopleInteraction
from oracle.models.query_log import QueryLog
from oracle.models.task import Task

AUTH_HEADERS = {"Authorization": f"Bearer {os.environ.get('BEARER_TOKEN', 'test-token')}"}

_test_engine = create_async_engine(settings.database_url, poolclass=NullPool)
_TestSession = async_sessionmaker(_test_engine, expire_on_commit=False)

_OPENAI_EMBEDDINGS_URL = "https://api.openai.com/v1/embeddings"
_OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions"

# A vector "close to" the query.
_QUERY_VEC = [1.0] + [0.0] * (EMBEDDING_DIM - 1)
# An orthogonal vector — cosine similarity ≈ 0.
_FAR_VEC = [0.0] + [1.0] + [0.0] * (EMBEDDING_DIM - 2)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
def override_db(monkeypatch) -> None:  # type: ignore[misc]
    from oracle.api.queries import get_log_session_factory
    from oracle.core.db import get_session
    from oracle.main import app

    async def _override_get_session() -> AsyncIterator[AsyncSession]:
        async with _TestSession() as session:
            yield session

    def _override_get_log_session_factory() -> async_sessionmaker[AsyncSession]:
        return _TestSession

    app.dependency_overrides[get_session] = _override_get_session
    app.dependency_overrides[get_log_session_factory] = _override_get_log_session_factory
    yield
    app.dependency_overrides.pop(get_session, None)
    app.dependency_overrides.pop(get_log_session_factory, None)


@pytest.fixture
async def db_session() -> AsyncIterator[AsyncSession]:
    async with _TestSession() as session:
        yield session


# ---------------------------------------------------------------------------
# HTTP response factories
# ---------------------------------------------------------------------------


def _make_openai_embedding_response(vec: list[float]) -> dict:
    return {
        "object": "list",
        "data": [{"object": "embedding", "index": 0, "embedding": vec}],
        "model": "text-embedding-3-small",
        "usage": {"prompt_tokens": 5, "total_tokens": 5},
    }


def _make_openrouter_response(content: str, prompt_tokens: int = 10, completion_tokens: int = 5) -> dict:
    return {
        "id": "gen-test",
        "choices": [{"message": {"role": "assistant", "content": content}, "finish_reason": "stop"}],
        "usage": {
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "total_tokens": prompt_tokens + completion_tokens,
        },
    }


def _intent_response(intents: list[str]) -> dict:
    """Build an OpenRouter response whose content is a valid intent JSON payload."""
    return _make_openrouter_response(json.dumps({"intents": intents}))


# ---------------------------------------------------------------------------
# Seed / cleanup helpers
# ---------------------------------------------------------------------------


async def _seed_memory(
    session: AsyncSession,
    embedding: list[float] | None = None,
    content: str = "A test memory.",
) -> uuid.UUID:
    memory_id = uuid.uuid4()
    session.add(
        Memory(
            id=memory_id,
            client_id=uuid.uuid4(),
            content=content,
            source_modality="text",
            source_device="test-device",
            language="en",
            captured_at=datetime(2025, 1, 1, tzinfo=UTC),
            enriched=False,
            embedding_model="text-embedding-3-small" if embedding else None,
            embedding=embedding,
        )
    )
    await session.commit()
    return memory_id


async def _delete_memory(session: AsyncSession, memory_id: uuid.UUID) -> None:
    from sqlalchemy import text

    await session.execute(
        text("DELETE FROM query_logs WHERE returned_memory_ids @> ARRAY[:mid]::uuid[]"),
        {"mid": str(memory_id)},
    )
    await session.commit()
    await session.execute(delete(Memory).where(Memory.id == memory_id))
    await session.commit()


async def _delete_all_query_logs_for_text(session: AsyncSession, query_text: str) -> None:
    await session.execute(delete(QueryLog).where(QueryLog.query_text == query_text))
    await session.commit()


# ---------------------------------------------------------------------------
# Unit tests: intent classifier output parser
# ---------------------------------------------------------------------------


class TestIntentParser:
    """Unit tests for parse_intent_response — no DB, no HTTP."""

    def test_happy_path_single_intent(self) -> None:
        from oracle.retrieval.intent_router import parse_intent_response

        result = parse_intent_response('{"intents": ["decisions"]}')
        assert result == ["decisions"]

    def test_happy_path_multiple_intents(self) -> None:
        from oracle.retrieval.intent_router import parse_intent_response

        result = parse_intent_response('{"intents": ["tasks", "appointments"]}')
        assert set(result) == {"tasks", "appointments"}

    def test_general_intent_returns_general(self) -> None:
        from oracle.retrieval.intent_router import parse_intent_response

        result = parse_intent_response('{"intents": ["general"]}')
        assert result == ["general"]

    def test_empty_intents_falls_back_to_general(self) -> None:
        from oracle.retrieval.intent_router import parse_intent_response

        result = parse_intent_response('{"intents": []}')
        assert result == ["general"]

    def test_malformed_json_falls_back_to_general(self) -> None:
        from oracle.retrieval.intent_router import parse_intent_response

        result = parse_intent_response("not json at all {{{")
        assert result == ["general"]

    def test_missing_intents_key_falls_back_to_general(self) -> None:
        from oracle.retrieval.intent_router import parse_intent_response

        result = parse_intent_response('{"something_else": ["decisions"]}')
        assert result == ["general"]

    def test_unknown_intent_values_are_filtered(self) -> None:
        from oracle.retrieval.intent_router import parse_intent_response

        result = parse_intent_response('{"intents": ["decisions", "unknown_category"]}')
        # unknown_category is silently dropped; decisions survives
        assert result == ["decisions"]

    def test_all_unknown_values_falls_back_to_general(self) -> None:
        from oracle.retrieval.intent_router import parse_intent_response

        result = parse_intent_response('{"intents": ["banana", "pineapple"]}')
        assert result == ["general"]


# ---------------------------------------------------------------------------
# Unit tests: specialised-table query helpers
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_query_decisions(db_session: AsyncSession) -> None:
    """query_decisions returns memory_ids for rows matching the query terms."""
    from oracle.retrieval.intent_router import query_decisions

    memory_id = await _seed_memory(db_session, content="Decided to use OAuth2 for auth.")
    try:
        decision = Decision(
            id=uuid.uuid4(),
            memory_id=memory_id,
            context="auth service migration planning",
            chosen_option="OAuth2",
            confidence=0.9,
            enrichment_version=1,
        )
        db_session.add(decision)
        await db_session.commit()

        results = await query_decisions(db_session, "OAuth2 decision")
        assert memory_id in results
    finally:
        await _delete_memory(db_session, memory_id)


@pytest.mark.asyncio
async def test_query_people(db_session: AsyncSession) -> None:
    """query_people returns memory_ids for rows matching a person's name."""
    from oracle.retrieval.intent_router import query_people

    memory_id = await _seed_memory(db_session, content="Had coffee with Alice.")
    try:
        interaction = PeopleInteraction(
            id=uuid.uuid4(),
            memory_id=memory_id,
            person_name="Alice",
            confidence=0.85,
            enrichment_version=1,
        )
        db_session.add(interaction)
        await db_session.commit()

        results = await query_people(db_session, "Alice meeting")
        assert memory_id in results
    finally:
        await _delete_memory(db_session, memory_id)


@pytest.mark.asyncio
async def test_query_tasks(db_session: AsyncSession) -> None:
    """query_tasks returns memory_ids for open tasks due in the relevant window."""
    from oracle.retrieval.intent_router import query_tasks

    memory_id = await _seed_memory(db_session, content="Need to send Alice the RFC draft.")
    try:
        task = Task(
            id=uuid.uuid4(),
            memory_id=memory_id,
            description="Send Alice the RFC draft",
            status="open",
            due_date=None,
            confidence=0.9,
            enrichment_version=1,
        )
        db_session.add(task)
        await db_session.commit()

        results = await query_tasks(db_session, "open tasks for Alice")
        assert memory_id in results
    finally:
        await _delete_memory(db_session, memory_id)


@pytest.mark.asyncio
async def test_query_appointments(db_session: AsyncSession) -> None:
    """query_appointments returns memory_ids for future appointments."""
    from oracle.retrieval.intent_router import query_appointments

    memory_id = await _seed_memory(db_session, content="Quarterly review booked for next month.")
    try:
        appointment = Appointment(
            id=uuid.uuid4(),
            memory_id=memory_id,
            title="Quarterly review",
            starts_at=datetime(2099, 7, 1, 10, 0, 0, tzinfo=UTC),
            confidence=0.9,
            enrichment_version=1,
        )
        db_session.add(appointment)
        await db_session.commit()

        results = await query_appointments(db_session, "upcoming meetings", forward_looking=True)
        assert memory_id in results
    finally:
        await _delete_memory(db_session, memory_id)


# ---------------------------------------------------------------------------
# Unit test: empty-table optimisation
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_empty_table_skipped(db_session: AsyncSession) -> None:
    """When decisions table is empty, the query is skipped and tables_searched reflects 'empty'."""
    from oracle.retrieval.intent_router import run_specialised_queries

    # Ensure decisions table is empty (it should be in a clean test environment,
    # but we verify the count-check path explicitly by passing an empty DB state).
    result = await run_specialised_queries(db_session, ["decisions"], "some query")
    assert result.tables_searched.get("decisions") == "empty"
    # No memory_ids returned from a skipped table.
    assert result.hits == []


# ---------------------------------------------------------------------------
# Integration: specialised match surfaces memory not in top-K vector results
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@respx.mock
async def test_specialised_hit_surfaces_non_topk_memory(db_session: AsyncSession) -> None:
    """A memory linked via specialised table appears in results even with a far embedding.

    We seed:
    - A memory with a close embedding (_QUERY_VEC) — would appear via vector search.
    - A memory with a far embedding (_FAR_VEC) — would NOT appear via vector search,
      but it has a Decision row matching the query terms.

    The intent router (mocked to return ["decisions"]) should surface the far memory.
    """
    from oracle.main import app

    close_id = await _seed_memory(db_session, embedding=_QUERY_VEC, content="Top-K vector hit memory.")
    far_id = await _seed_memory(
        db_session,
        embedding=_FAR_VEC,
        content="Decided to adopt PostgreSQL for the project database.",
    )
    try:
        # Seed a decision row for the far memory.
        db_session.add(
            Decision(
                id=uuid.uuid4(),
                memory_id=far_id,
                context="database selection",
                chosen_option="PostgreSQL",
                confidence=0.92,
                enrichment_version=1,
            )
        )
        await db_session.commit()

        # Mock embedding call.
        respx.post(_OPENAI_EMBEDDINGS_URL).mock(
            return_value=httpx.Response(200, json=_make_openai_embedding_response(_QUERY_VEC))
        )
        # Mock intent router call — returns "decisions" intent.
        # Mock synthesis call too — return a trivial answer.
        # The intent router call happens FIRST, synthesis SECOND.
        # We use side_effect to return different responses per call.
        call_count = {"n": 0}

        def _openrouter_side_effect(request: httpx.Request) -> httpx.Response:
            call_count["n"] += 1
            if call_count["n"] == 1:
                # Intent router call
                return httpx.Response(200, json=_intent_response(["decisions"]))
            else:
                # Synthesis call
                return httpx.Response(
                    200,
                    json=_make_openrouter_response("PostgreSQL was chosen for the database."),
                )

        respx.post(_OPENROUTER_URL).mock(side_effect=_openrouter_side_effect)

        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.post(
                "/v1/queries",
                json={"query": "database decision PostgreSQL", "limit": 1},
                headers=AUTH_HEADERS,
            )

        assert response.status_code == 200
        body = response.json()
        source_ids = {s["memory_id"] for s in body["sources"]}
        # The far memory must appear despite limit=1 (specialised boost overrides top-K).
        assert str(far_id) in source_ids
    finally:
        await _delete_memory(db_session, close_id)
        await _delete_memory(db_session, far_id)


# ---------------------------------------------------------------------------
# Integration: tables_searched populated for every query
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@respx.mock
async def test_tables_searched_populated(db_session: AsyncSession) -> None:
    """tables_searched on query_logs contains intent router results."""
    from oracle.main import app

    query_text = f"tables_searched_test_{uuid.uuid4().hex}"
    memory_id = await _seed_memory(db_session, embedding=_QUERY_VEC, content="Test memory.")
    try:
        respx.post(_OPENAI_EMBEDDINGS_URL).mock(
            return_value=httpx.Response(200, json=_make_openai_embedding_response(_QUERY_VEC))
        )
        # Intent router says "general" — no specialised queries.
        call_count = {"n": 0}

        def _openrouter_side_effect(request: httpx.Request) -> httpx.Response:
            call_count["n"] += 1
            if call_count["n"] == 1:
                return httpx.Response(200, json=_intent_response(["general"]))
            return httpx.Response(200, json=_make_openrouter_response("An answer."))

        respx.post(_OPENROUTER_URL).mock(side_effect=_openrouter_side_effect)

        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.post(
                "/v1/queries",
                json={"query": query_text, "limit": 50},
                headers=AUTH_HEADERS,
            )

        assert response.status_code == 200
        body = response.json()
        log_id = uuid.UUID(body["query_id"])

        log_row = await db_session.get(QueryLog, log_id)
        assert log_row is not None
        ts = log_row.tables_searched
        assert isinstance(ts, dict)
        assert ts.get("vector") is True
        # general intent means no specialised tables queried
        assert "decisions" in ts
        assert "people_interactions" in ts
        assert "tasks" in ts
        assert "appointments" in ts
    finally:
        await _delete_memory(db_session, memory_id)
        await _delete_all_query_logs_for_text(db_session, query_text)


# ---------------------------------------------------------------------------
# Integration: intent router cost stamped on query_logs
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@respx.mock
async def test_intent_router_cost_stamped(db_session: AsyncSession) -> None:
    """intent_router_cost, _input_tokens, _output_tokens, _model are stamped per query."""
    from oracle.main import app

    query_text = f"cost_stamp_test_{uuid.uuid4().hex}"
    memory_id = await _seed_memory(db_session, embedding=_QUERY_VEC, content="Cost test memory.")
    try:
        respx.post(_OPENAI_EMBEDDINGS_URL).mock(
            return_value=httpx.Response(200, json=_make_openai_embedding_response(_QUERY_VEC))
        )
        call_count = {"n": 0}

        def _openrouter_side_effect(request: httpx.Request) -> httpx.Response:
            call_count["n"] += 1
            if call_count["n"] == 1:
                # Intent router call — include cost header
                return httpx.Response(
                    200,
                    json=_intent_response(["general"]),
                    headers={"x-openrouter-cost": "0.00042"},
                )
            return httpx.Response(200, json=_make_openrouter_response("Answer."))

        respx.post(_OPENROUTER_URL).mock(side_effect=_openrouter_side_effect)

        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.post(
                "/v1/queries",
                json={"query": query_text, "limit": 50},
                headers=AUTH_HEADERS,
            )

        assert response.status_code == 200
        body = response.json()
        log_id = uuid.UUID(body["query_id"])

        log_row = await db_session.get(QueryLog, log_id)
        assert log_row is not None
        assert log_row.intent_router_model is not None
        assert log_row.intent_router_input_tokens is not None and log_row.intent_router_input_tokens > 0
        assert log_row.intent_router_output_tokens is not None and log_row.intent_router_output_tokens > 0
        assert log_row.intent_router_cost is not None
        assert float(log_row.intent_router_cost) == pytest.approx(0.00042)
    finally:
        await _delete_memory(db_session, memory_id)
        await _delete_all_query_logs_for_text(db_session, query_text)
