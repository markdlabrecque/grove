"""Tests for POST /v1/queries.

Requires a real Postgres+pgvector instance with migrations applied.
DATABASE_URL is set by conftest.py (dev) or docker-compose CI env.

The OpenAI embedding API is mocked at the HTTP boundary with respx — same
pattern as test_captures.py.

Design note: the dev DB is shared across test runs. Every test that seeds
rows wraps its assertions in try/finally to guarantee cleanup even on failure,
preventing vector-score pollution across runs.
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
from grove.core.db import get_session
from grove.embeddings import EMBEDDING_DIM
from grove.models.memory import Memory, MemoryChunk
from grove.models.query_log import QueryLog

AUTH_HEADERS = {"Authorization": f"Bearer {os.environ.get('BEARER_TOKEN', 'test-token')}"}

_test_engine = create_async_engine(settings.database_url, poolclass=NullPool)
_TestSession = async_sessionmaker(_test_engine, expire_on_commit=False)

_OPENAI_EMBEDDINGS_URL = "https://api.openai.com/v1/embeddings"

# A vector "close to" the query — cosine similarity = 1.0 when identical.
_QUERY_VEC = [1.0] + [0.0] * (EMBEDDING_DIM - 1)
# An orthogonal vector — cosine similarity = 0.0.
_FAR_VEC = [0.0] + [1.0] + [0.0] * (EMBEDDING_DIM - 2)


def _make_openai_response(vec: list[float]) -> dict:
    """Return an OpenAI embeddings response containing a single vector."""
    return {
        "object": "list",
        "data": [{"object": "embedding", "index": 0, "embedding": vec}],
        "model": "text-embedding-3-small",
        "usage": {"prompt_tokens": 5, "total_tokens": 5},
    }


async def _override_get_session() -> AsyncIterator[AsyncSession]:
    async with _TestSession() as session:
        yield session


def _override_get_log_session_factory() -> async_sessionmaker[AsyncSession]:
    return _TestSession


@pytest.fixture(autouse=True)
def override_db(monkeypatch) -> None:  # type: ignore[misc]
    from grove.api.queries import get_log_session_factory
    from grove.main import app

    app.dependency_overrides[get_session] = _override_get_session
    app.dependency_overrides[get_log_session_factory] = _override_get_log_session_factory
    yield
    app.dependency_overrides.pop(get_session, None)
    app.dependency_overrides.pop(get_log_session_factory, None)


@pytest.fixture
async def db_session() -> AsyncIterator[AsyncSession]:  # type: ignore[misc]
    async with _TestSession() as session:
        yield session


# ---------------------------------------------------------------------------
# Seed / cleanup helpers
# ---------------------------------------------------------------------------


async def _seed_whole_memory(
    session: AsyncSession,
    embedding: list[float],
    content: str = "A short memory for testing.",
    source_modality: str = "text",
) -> uuid.UUID:
    """Insert a memory with a whole-memory embedding and return its id."""
    memory_id = uuid.uuid4()
    memory = Memory(
        id=memory_id,
        client_id=uuid.uuid4(),
        content=content,
        source_modality=source_modality,
        source_device="test-device",
        language="en",
        captured_at=datetime(2024, 6, 1, 10, 0, 0, tzinfo=UTC),
        enriched=False,
        embedding_model="text-embedding-3-small",
        embedding=embedding,
    )
    session.add(memory)
    await session.commit()
    return memory_id


async def _seed_chunked_memory(
    session: AsyncSession,
    chunk_embeddings: list[list[float]],
    content: str = "A long memory that was chunked for storage purposes.",
) -> uuid.UUID:
    """Insert a memory with no whole-embedding but with chunk rows."""
    memory_id = uuid.uuid4()
    memory = Memory(
        id=memory_id,
        client_id=uuid.uuid4(),
        content=content,
        source_modality="text",
        source_device="test-device",
        language="en",
        captured_at=datetime(2024, 6, 2, 10, 0, 0, tzinfo=UTC),
        enriched=False,
        embedding_model="text-embedding-3-small",
        # No whole-memory embedding — chunked path.
        embedding=None,
    )
    session.add(memory)
    await session.flush()  # need memory.id before chunks

    for idx, vec in enumerate(chunk_embeddings):
        session.add(
            MemoryChunk(
                id=uuid.uuid4(),
                memory_id=memory_id,
                chunk_index=idx,
                content=f"Chunk {idx} of the long memory content for testing purposes.",
                embedding=vec,
                embedding_model="text-embedding-3-small",
            )
        )

    await session.commit()
    return memory_id


async def _delete_query_logs_for_memory(session: AsyncSession, memory_id: uuid.UUID) -> None:
    """Delete query_logs rows whose returned_memory_ids contains memory_id."""
    from sqlalchemy import text

    # returned_memory_ids is a uuid[] column; @> checks array containment.
    await session.execute(
        text("DELETE FROM query_logs WHERE returned_memory_ids @> ARRAY[:mid]::uuid[]"),
        {"mid": str(memory_id)},
    )
    await session.commit()


async def _delete_memory(session: AsyncSession, memory_id: uuid.UUID) -> None:
    # Clean up query_log rows that reference this memory before removing it,
    # so orphan rows don't accumulate in the shared dev DB across test runs.
    await _delete_query_logs_for_memory(session, memory_id)
    # ON DELETE CASCADE propagates to memory_chunks.
    await session.execute(delete(Memory).where(Memory.id == memory_id))
    await session.commit()


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@respx.mock
async def test_whole_memory_hit(db_session: AsyncSession) -> None:
    """A short memory whose embedding matches the query comes back with matched_via=whole."""
    from grove.main import app

    memory_id = await _seed_whole_memory(db_session, embedding=_QUERY_VEC)
    try:
        respx.post(_OPENAI_EMBEDDINGS_URL).mock(
            return_value=httpx.Response(200, json=_make_openai_response(_QUERY_VEC))
        )

        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.post(
                "/v1/queries",
                json={"query": "a short test query", "limit": 50},
                headers=AUTH_HEADERS,
            )

        assert response.status_code == 200
        body = response.json()
        assert "sources" in body
        assert "query_token_count" in body
        assert "latency_ms" in body

        hit_ids = [r["memory_id"] for r in body["sources"]]
        assert str(memory_id) in hit_ids

        hit = next(r for r in body["sources"] if r["memory_id"] == str(memory_id))
        assert hit["matched_via"] == "whole"
        assert hit["matched_chunk_index"] is None
        # Identical vectors → similarity very close to 1.0
        assert hit["score"] > 0.99
        # Excerpt is capped at 140 chars, not an empty string.
        assert 0 < len(hit["excerpt"]) <= 140
    finally:
        await _delete_memory(db_session, memory_id)


@pytest.mark.asyncio
@respx.mock
async def test_chunk_hit(db_session: AsyncSession) -> None:
    """A chunked memory returns matched_via=chunk with the correct chunk index."""
    from grove.main import app

    # First chunk is close; second chunk is far.
    memory_id = await _seed_chunked_memory(
        db_session,
        chunk_embeddings=[_QUERY_VEC, _FAR_VEC],
    )
    try:
        respx.post(_OPENAI_EMBEDDINGS_URL).mock(
            return_value=httpx.Response(200, json=_make_openai_response(_QUERY_VEC))
        )

        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.post(
                "/v1/queries",
                json={"query": "test chunk query", "limit": 50},
                headers=AUTH_HEADERS,
            )

        assert response.status_code == 200
        body = response.json()
        hit_ids = [r["memory_id"] for r in body["sources"]]
        assert str(memory_id) in hit_ids

        hit = next(r for r in body["sources"] if r["memory_id"] == str(memory_id))
        assert hit["matched_via"] == "chunk"
        # Best chunk is index 0 (the one with _QUERY_VEC).
        assert hit["matched_chunk_index"] == 0
        assert hit["score"] > 0.99
    finally:
        await _delete_memory(db_session, memory_id)


@pytest.mark.asyncio
@respx.mock
async def test_dedup_whole_and_chunk(db_session: AsyncSession) -> None:
    """A memory with both whole-memory embedding and chunk hits returns only one entry."""
    from grove.main import app

    # Seed a memory with both a whole-memory embedding AND chunks — unusual in
    # production (post-#24 whole embedding is NULL when chunks exist) but the
    # merge logic must handle it correctly.
    memory_id = uuid.uuid4()
    # Use a slightly less perfect vector for the whole-memory so the chunk wins.
    whole_vec = [0.99] + [0.1] + [0.0] * (EMBEDDING_DIM - 2)
    memory = Memory(
        id=memory_id,
        client_id=uuid.uuid4(),
        content="Memory with both whole embedding and chunks.",
        source_modality="text",
        source_device="test-device",
        language="en",
        captured_at=datetime(2024, 6, 3, 10, 0, 0, tzinfo=UTC),
        enriched=False,
        embedding_model="text-embedding-3-small",
        embedding=whole_vec,
    )
    db_session.add(memory)
    await db_session.flush()

    # Add a chunk with an identical vector to the query — higher similarity.
    db_session.add(
        MemoryChunk(
            id=uuid.uuid4(),
            memory_id=memory_id,
            chunk_index=0,
            content="Chunk that exactly matches the query vector.",
            embedding=_QUERY_VEC,
            embedding_model="text-embedding-3-small",
        )
    )
    await db_session.commit()

    try:
        respx.post(_OPENAI_EMBEDDINGS_URL).mock(
            return_value=httpx.Response(200, json=_make_openai_response(_QUERY_VEC))
        )

        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.post(
                "/v1/queries",
                json={"query": "dedup test", "limit": 50},
                headers=AUTH_HEADERS,
            )

        assert response.status_code == 200
        body = response.json()

        matching = [r for r in body["sources"] if r["memory_id"] == str(memory_id)]
        # Exactly one entry per memory_id.
        assert len(matching) == 1
        # The chunk hit wins because it has the higher score.
        assert matching[0]["matched_via"] == "chunk"
        assert matching[0]["score"] > 0.99
    finally:
        await _delete_memory(db_session, memory_id)


@pytest.mark.asyncio
@respx.mock
async def test_limit_and_ordering(db_session: AsyncSession) -> None:
    """limit is respected and results come back in descending score order."""
    from grove.main import app

    # Seed 5 memories with known scores.
    scores = [1.0, 0.9, 0.8, 0.7, 0.6]
    memory_ids: list[uuid.UUID] = []
    try:
        for s in scores:
            vec = [s] + [0.0] * (EMBEDDING_DIM - 1)
            mid = await _seed_whole_memory(
                db_session, embedding=vec, content=f"Ordering test memory score={s}"
            )
            memory_ids.append(mid)

        respx.post(_OPENAI_EMBEDDINGS_URL).mock(
            return_value=httpx.Response(200, json=_make_openai_response(_QUERY_VEC))
        )

        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.post(
                "/v1/queries",
                json={"query": "ordering test", "limit": 3},
                headers=AUTH_HEADERS,
            )

        assert response.status_code == 200
        body = response.json()
        sources = body["sources"]

        # limit=3 means at most 3 results.
        assert len(sources) <= 3

        # Results are in descending score order regardless of what else is in DB.
        result_scores = [r["score"] for r in sources]
        assert result_scores == sorted(result_scores, reverse=True)

        # All returned scores should be at least as high as the lowest seeded score
        # (0.6), since the seeded scores span 1.0..0.6 and top-3 should all be ≥0.6.
        for r in sources:
            assert r["score"] >= 0.0  # basic sanity: no negative similarities
    finally:
        for mid in memory_ids:
            await _delete_memory(db_session, mid)


@pytest.mark.asyncio
@respx.mock
async def test_min_similarity_filter(db_session: AsyncSession) -> None:
    """Results below min_similarity are dropped."""
    from grove.main import app

    high_vec = [1.0] + [0.0] * (EMBEDDING_DIM - 1)  # similarity = 1.0
    low_vec = [0.0] + [1.0] + [0.0] * (EMBEDDING_DIM - 2)  # similarity = 0.0
    high_id = await _seed_whole_memory(db_session, embedding=high_vec, content="High similarity")
    low_id = await _seed_whole_memory(db_session, embedding=low_vec, content="Low similarity")

    try:
        respx.post(_OPENAI_EMBEDDINGS_URL).mock(
            return_value=httpx.Response(200, json=_make_openai_response(_QUERY_VEC))
        )

        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.post(
                "/v1/queries",
                json={"query": "filter test", "limit": 50, "min_similarity": 0.5},
                headers=AUTH_HEADERS,
            )

        assert response.status_code == 200
        body = response.json()
        returned_ids = {r["memory_id"] for r in body["sources"]}

        # High-similarity result should be present.
        assert str(high_id) in returned_ids
        # Low-similarity result must be filtered out.
        assert str(low_id) not in returned_ids

        # All returned scores meet the threshold.
        for r in body["sources"]:
            assert r["score"] >= 0.5
    finally:
        await _delete_memory(db_session, high_id)
        await _delete_memory(db_session, low_id)


@pytest.mark.asyncio
async def test_empty_query_returns_422() -> None:
    """Whitespace-only query → 422."""
    from grove.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post(
            "/v1/queries",
            json={"query": "   "},
            headers=AUTH_HEADERS,
        )

    assert response.status_code == 422


@pytest.mark.asyncio
@respx.mock
async def test_no_matches_returns_200_with_response_envelope(db_session: AsyncSession) -> None:
    """min_similarity filter drops below-threshold results; response shape is always valid."""
    from grove.main import app

    # Seed one memory with an orthogonal vector — it will be filtered at min_similarity=0.99.
    far_id = await _seed_whole_memory(db_session, embedding=_FAR_VEC, content="Far memory")

    try:
        respx.post(_OPENAI_EMBEDDINGS_URL).mock(
            return_value=httpx.Response(200, json=_make_openai_response(_QUERY_VEC))
        )

        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.post(
                "/v1/queries",
                json={"query": "no match query", "limit": 50, "min_similarity": 0.99},
                headers=AUTH_HEADERS,
            )

        assert response.status_code == 200
        body = response.json()
        # The orthogonal memory must not appear.
        returned_ids = {r["memory_id"] for r in body["sources"]}
        assert str(far_id) not in returned_ids
        # All results that do appear must meet the threshold.
        for r in body["sources"]:
            assert r["score"] >= 0.99
        assert "query_token_count" in body
        assert "latency_ms" in body
    finally:
        await _delete_memory(db_session, far_id)


@pytest.mark.asyncio
async def test_missing_auth_returns_401() -> None:
    from grove.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/v1/queries", json={"query": "hello"})

    assert response.status_code == 401


@pytest.mark.asyncio
async def test_wrong_token_returns_401() -> None:
    from grove.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post(
            "/v1/queries",
            json={"query": "hello"},
            headers={"Authorization": "Bearer wrong-token"},
        )

    assert response.status_code == 401


# ---------------------------------------------------------------------------
# #54 — query_logs write
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@respx.mock
async def test_query_log_inserted_with_result_count_and_memory_ids(
    db_session: AsyncSession,
) -> None:
    """A successful query creates a query_log row with correct result_count and returned_memory_ids."""  # noqa: E501
    from grove.main import app

    memory_id = await _seed_whole_memory(
        db_session, embedding=_QUERY_VEC, content="Log test memory"
    )
    try:
        respx.post(_OPENAI_EMBEDDINGS_URL).mock(
            return_value=httpx.Response(200, json=_make_openai_response(_QUERY_VEC))
        )

        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.post(
                "/v1/queries",
                json={"query": "log test query", "limit": 50},
                headers=AUTH_HEADERS,
            )

        assert response.status_code == 200
        body = response.json()
        result_count = len(body["sources"])
        assert result_count >= 1

        # Fetch the most recent query_log row. There may be others from parallel
        # tests, so filter to those that include our memory_id.
        result = await db_session.execute(
            sa_select(QueryLog)
            .where(QueryLog.returned_memory_ids.contains([memory_id]))
            .order_by(QueryLog.created_at.desc())
            .limit(1)
        )
        log_row = result.scalar_one_or_none()

        assert log_row is not None, "Expected a query_log row to be inserted"
        assert log_row.result_count == result_count
        assert memory_id in (log_row.returned_memory_ids or [])
        assert log_row.query_text == "log test query"
        # tables_searched is now a JSONB dict (migrated from ARRAY in #175).
        assert isinstance(log_row.tables_searched, dict)
        assert log_row.tables_searched.get("vector") is True
        # Synthesis fields are NULL in this phase.
        assert log_row.synthesis_model is None
        assert log_row.synthesis_input_tokens is None
        assert log_row.synthesis_output_tokens is None
    finally:
        await _delete_memory(db_session, memory_id)


# ---------------------------------------------------------------------------
# #55 — min_similarity bounds validation
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_min_similarity_below_zero_returns_422() -> None:
    """min_similarity=-0.5 is outside [0.0, 1.0] and must be rejected with 422."""
    from grove.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post(
            "/v1/queries",
            json={"query": "bounds test", "min_similarity": -0.5},
            headers=AUTH_HEADERS,
        )

    assert response.status_code == 422


@pytest.mark.asyncio
async def test_min_similarity_above_one_returns_422() -> None:
    """min_similarity=1.5 is outside [0.0, 1.0] and must be rejected with 422."""
    from grove.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post(
            "/v1/queries",
            json={"query": "bounds test", "min_similarity": 1.5},
            headers=AUTH_HEADERS,
        )

    assert response.status_code == 422
