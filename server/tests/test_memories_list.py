"""Tests for GET /v1/memories list endpoint.

Requires a real Postgres+pgvector instance with migrations applied.
DATABASE_URL is set by conftest.py (dev) or docker-compose CI env.
"""

from __future__ import annotations

import os
import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.pool import NullPool

from oracle.core.config import settings
from oracle.models.memory import Memory

AUTH_HEADERS = {"Authorization": f"Bearer {os.environ.get('BEARER_TOKEN', 'test-token')}"}

_test_engine = create_async_engine(settings.database_url, poolclass=NullPool)
_TestSession = async_sessionmaker(_test_engine, expire_on_commit=False)


async def _override_get_session() -> AsyncIterator[AsyncSession]:
    async with _TestSession() as session:
        yield session


@pytest.fixture(autouse=True)
def override_db(monkeypatch) -> None:  # type: ignore[misc]
    from oracle.core.db import get_session
    from oracle.main import app

    app.dependency_overrides[get_session] = _override_get_session
    yield
    app.dependency_overrides.pop(get_session, None)


@pytest.fixture
async def db_session() -> AsyncIterator[AsyncSession]:
    async with _TestSession() as session:
        yield session


def _make_memory(
    *,
    content: str = "Test memory content",
    enriched: bool = False,
    created_at: datetime | None = None,
    language: str = "en",
    source_modality: str = "text",
) -> Memory:
    """Build an unsaved Memory with a unique client_id."""
    kwargs: dict = dict(
        id=uuid.uuid4(),
        client_id=uuid.uuid4(),
        content=content,
        enriched=enriched,
        language=language,
        source_modality=source_modality,
        captured_at=datetime(2024, 1, 1, tzinfo=UTC),
    )
    if created_at is not None:
        kwargs["created_at"] = created_at
    return Memory(**kwargs)


@pytest.fixture
async def five_memories(db_session: AsyncSession) -> AsyncIterator[list[Memory]]:
    """Insert 5 memories at known, distinct timestamps and clean up after."""
    base = datetime(2024, 6, 1, 12, 0, 0, tzinfo=UTC)
    memories = [
        _make_memory(content=f"Memory {i}", created_at=base + timedelta(minutes=i))
        for i in range(5)
    ]
    db_session.add_all(memories)
    await db_session.commit()
    for m in memories:
        await db_session.refresh(m)

    yield memories

    for m in memories:
        await db_session.delete(m)
    await db_session.commit()


# ---------------------------------------------------------------------------
# 401 — missing auth (smoke)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_missing_auth_returns_401() -> None:
    from oracle.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/v1/memories")

    assert response.status_code == 401


# ---------------------------------------------------------------------------
# Empty result set
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_empty_result_set_via_filter(db_session: AsyncSession) -> None:
    """Filter to a time window in the future produces an empty list + null cursor."""
    from oracle.main import app

    future = datetime(2099, 1, 1, tzinfo=UTC).isoformat()
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get(
            "/v1/memories", headers=AUTH_HEADERS, params={"created_after": future}
        )

    assert response.status_code == 200
    body = response.json()
    assert body["items"] == []
    assert body["next_cursor"] is None


# ---------------------------------------------------------------------------
# Ordering: 5 memories returned in created_at DESC order
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_list_returns_correct_order(five_memories: list[Memory]) -> None:
    from oracle.main import app

    # Scope to the exact time window of our fixtures to avoid pollution from
    # other tests that insert memories at later timestamps.
    sorted_by_time = sorted(five_memories, key=lambda m: m.created_at)
    window_start = (sorted_by_time[0].created_at - timedelta(seconds=1)).isoformat()
    window_end = (sorted_by_time[-1].created_at + timedelta(seconds=1)).isoformat()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get(
            "/v1/memories",
            headers=AUTH_HEADERS,
            params={"limit": 10, "created_after": window_start, "created_before": window_end},
        )

    assert response.status_code == 200
    body = response.json()
    our_items = body["items"]

    assert len(our_items) == 5

    # Items must appear in descending created_at order.
    timestamps = [item["created_at"] for item in our_items]
    assert timestamps == sorted(timestamps, reverse=True)


# ---------------------------------------------------------------------------
# Summary fields — no full content, no embedding in response
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_summary_fields_present(five_memories: list[Memory]) -> None:
    from oracle.main import app

    sorted_by_time = sorted(five_memories, key=lambda m: m.created_at)
    window_start = (sorted_by_time[0].created_at - timedelta(seconds=1)).isoformat()
    window_end = (sorted_by_time[-1].created_at + timedelta(seconds=1)).isoformat()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get(
            "/v1/memories",
            headers=AUTH_HEADERS,
            params={"limit": 10, "created_after": window_start, "created_before": window_end},
        )

    assert response.status_code == 200
    items = response.json()["items"]
    assert items

    item = items[0]
    # Required summary fields.
    for field in (
        "id",
        "client_id",
        "captured_at",
        "created_at",
        "enriched",
        "language",
        "source_modality",
        "content_preview",
    ):
        assert field in item, f"missing field: {field}"

    # These must NOT appear in the summary.
    for forbidden in (
        "content",
        "embedding",
        "enrichment_error",
        "chunks",
        "decisions",
        "people_interactions",
        "tasks",
        "appointments",
    ):
        assert forbidden not in item, f"forbidden field present: {forbidden}"


@pytest.mark.asyncio
async def test_content_preview_truncated() -> None:
    from oracle.main import app

    long_content = "x" * 200
    memory = _make_memory(content=long_content)

    async with _TestSession() as session:
        session.add(memory)
        await session.commit()

    try:
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            response = await client.get(
                "/v1/memories",
                headers=AUTH_HEADERS,
                params={"limit": 200},
            )

        our_item = next((i for i in response.json()["items"] if i["id"] == str(memory.id)), None)
        assert our_item is not None
        assert our_item["content_preview"] == "x" * 140
    finally:
        async with _TestSession() as session:
            m = await session.get(Memory, memory.id)
            if m:
                await session.delete(m)
                await session.commit()


# ---------------------------------------------------------------------------
# Cursor pagination
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_cursor_pagination(five_memories: list[Memory]) -> None:
    """limit=2 pages through all 5 memories without duplicates or gaps."""
    from oracle.main import app

    our_ids = {str(m.id) for m in five_memories}
    collected: list[str] = []
    cursor: str | None = None

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        while True:
            params: dict = {"limit": 2}
            if cursor:
                params["cursor"] = cursor

            response = await client.get("/v1/memories", headers=AUTH_HEADERS, params=params)
            assert response.status_code == 200
            body = response.json()

            page_our_ids = [i["id"] for i in body["items"] if i["id"] in our_ids]
            collected.extend(page_our_ids)

            cursor = body["next_cursor"]
            if cursor is None:
                break

    # All 5 must appear exactly once.
    assert len(collected) == 5
    assert set(collected) == our_ids


@pytest.mark.asyncio
async def test_cursor_no_duplicates_across_pages(five_memories: list[Memory]) -> None:
    """Verify no ID appears on more than one page within the fixture's time window."""
    from oracle.main import app

    sorted_by_time = sorted(five_memories, key=lambda m: m.created_at)
    window_start = (sorted_by_time[0].created_at - timedelta(seconds=1)).isoformat()
    window_end = (sorted_by_time[-1].created_at + timedelta(seconds=1)).isoformat()

    seen: set[str] = set()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        cursor: str | None = None
        while True:
            params: dict = {
                "limit": 2,
                "created_after": window_start,
                "created_before": window_end,
            }
            if cursor:
                params["cursor"] = cursor

            response = await client.get("/v1/memories", headers=AUTH_HEADERS, params=params)
            body = response.json()

            page_ids = [i["id"] for i in body["items"]]
            for pid in page_ids:
                assert pid not in seen, f"duplicate id across pages: {pid}"
                seen.add(pid)

            cursor = body["next_cursor"]
            if cursor is None:
                break

    assert len(seen) == 5


# ---------------------------------------------------------------------------
# enriched filter
# ---------------------------------------------------------------------------


@pytest.fixture
async def mixed_enrichment_memories(db_session: AsyncSession) -> AsyncIterator[list[Memory]]:
    """3 unenriched + 2 enriched memories."""
    base = datetime(2024, 7, 1, 12, 0, 0, tzinfo=UTC)
    unenriched = [
        _make_memory(
            content=f"Unenriched {i}", enriched=False, created_at=base + timedelta(minutes=i)
        )
        for i in range(3)
    ]
    enriched = [
        _make_memory(
            content=f"Enriched {i}", enriched=True, created_at=base + timedelta(minutes=i + 10)
        )
        for i in range(2)
    ]
    all_memories = unenriched + enriched
    db_session.add_all(all_memories)
    await db_session.commit()
    for m in all_memories:
        await db_session.refresh(m)

    yield all_memories

    for m in all_memories:
        await db_session.delete(m)
    await db_session.commit()


@pytest.mark.asyncio
async def test_enriched_true_filter(mixed_enrichment_memories: list[Memory]) -> None:
    from oracle.main import app

    our_ids = {str(m.id) for m in mixed_enrichment_memories}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get(
            "/v1/memories", headers=AUTH_HEADERS, params={"enriched": "true", "limit": 50}
        )

    assert response.status_code == 200
    our_items = [i for i in response.json()["items"] if i["id"] in our_ids]
    assert len(our_items) == 2
    assert all(i["enriched"] is True for i in our_items)


@pytest.mark.asyncio
async def test_enriched_false_filter(mixed_enrichment_memories: list[Memory]) -> None:
    from oracle.main import app

    our_ids = {str(m.id) for m in mixed_enrichment_memories}

    # Scope to the fixture's time window so rows inserted by other tests (e.g.
    # the e2e capture harness, which lands at now()) don't fill the page and
    # push fixture rows out of the limit=50 window.
    sorted_by_time = sorted(mixed_enrichment_memories, key=lambda m: m.created_at)
    window_start = (sorted_by_time[0].created_at - timedelta(seconds=1)).isoformat()
    window_end = (sorted_by_time[-1].created_at + timedelta(seconds=1)).isoformat()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get(
            "/v1/memories",
            headers=AUTH_HEADERS,
            params={
                "enriched": "false",
                "limit": 50,
                "created_after": window_start,
                "created_before": window_end,
            },
        )

    assert response.status_code == 200
    our_items = [i for i in response.json()["items"] if i["id"] in our_ids]
    assert len(our_items) == 3
    assert all(i["enriched"] is False for i in our_items)


# ---------------------------------------------------------------------------
# created_after / created_before filters
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_created_after_filter(five_memories: list[Memory]) -> None:
    from oracle.main import app

    # The memories are at base + 0..4 minutes. Use the 3rd memory's created_at
    # as the lower bound — should return memories 3 and 4 (indices 3, 4).
    sorted_by_time = sorted(five_memories, key=lambda m: m.created_at)
    cutoff = sorted_by_time[2].created_at.isoformat()
    expected_ids = {str(m.id) for m in sorted_by_time[3:]}

    # Cap the window just past the last fixture row so that e2e-inserted rows
    # (which land at now() / 2026) do not fill the page and push our rows out.
    window_end = (sorted_by_time[-1].created_at + timedelta(seconds=1)).isoformat()

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get(
            "/v1/memories",
            headers=AUTH_HEADERS,
            params={"created_after": cutoff, "created_before": window_end, "limit": 50},
        )

    assert response.status_code == 200
    our_items = [
        i for i in response.json()["items"] if i["id"] in {str(m.id) for m in five_memories}
    ]
    returned_ids = {i["id"] for i in our_items}
    assert returned_ids == expected_ids


@pytest.mark.asyncio
async def test_created_before_filter(five_memories: list[Memory]) -> None:
    from oracle.main import app

    sorted_by_time = sorted(five_memories, key=lambda m: m.created_at)
    cutoff = sorted_by_time[3].created_at.isoformat()
    expected_ids = {str(m.id) for m in sorted_by_time[:3]}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get(
            "/v1/memories",
            headers=AUTH_HEADERS,
            params={"created_before": cutoff, "limit": 50},
        )

    assert response.status_code == 200
    our_items = [
        i for i in response.json()["items"] if i["id"] in {str(m.id) for m in five_memories}
    ]
    returned_ids = {i["id"] for i in our_items}
    assert returned_ids == expected_ids


# ---------------------------------------------------------------------------
# Invalid cursor
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_invalid_cursor_returns_422() -> None:
    from oracle.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get(
            "/v1/memories", headers=AUTH_HEADERS, params={"cursor": "not-valid-base64!!!"}
        )

    assert response.status_code == 422
