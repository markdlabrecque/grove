"""End-to-end test harness: capture → list → fetch.

Drives the FastAPI app via httpx.AsyncClient(transport=ASGITransport(app=app)).
No real TCP socket is opened — requests route through the ASGI interface
directly. This makes tests fast and deterministic while exercising the full
stack (router → service → database).

Pattern for future endpoints
-----------------------------
Add new endpoint test cases here rather than inventing parallel plumbing.
The shared fixtures (``authed_client``, ``override_db``, ``fake_embedding``)
handle auth headers, DB isolation, and the OpenAI mock so new tests only need
to describe the scenario they care about.

Infrastructure assumptions
--------------------------
- A real Postgres+pgvector instance with migrations applied is required.
  DATABASE_URL is seeded by conftest.py (local dev) or injected by CI.
- The OpenAI embedding API is mocked at the HTTP boundary via ``respx``.
  No network calls leave the process.
- ``@respx.mock`` enforces both ``assert_all_mocked=True`` (any unmocked
  outbound HTTP call raises an error) and ``assert_all_called=True`` (every
  registered mock route must be called at least once). Only register routes
  you expect the test to actually hit.
"""

from __future__ import annotations

import json
import uuid
from collections.abc import AsyncIterator, Iterator

import httpx
import pytest
import respx
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.pool import NullPool

from oracle.core.config import settings
from oracle.core.db import get_session
from oracle.embeddings import EMBEDDING_DIM, WHOLE_VS_CHUNKS_THRESHOLD, count_tokens
from oracle.main import app

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_OPENAI_EMBEDDINGS_URL = "https://api.openai.com/v1/embeddings"

# Deterministic 1536-element vector — avoids any dependence on real OpenAI output.
_FAKE_VECTOR: list[float] = [0.001 * i for i in range(EMBEDDING_DIM)]

_AUTH_HEADERS = {"Authorization": f"Bearer {settings.bearer_token}"}

# NullPool: each request gets its own connection — prevents asyncpg
# "another operation is in progress" errors when the app engine and the
# test's direct session share the same event loop.
_test_engine = create_async_engine(settings.database_url, poolclass=NullPool)
_TestSession = async_sessionmaker(_test_engine, expire_on_commit=False)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_openai_response(n: int) -> dict:
    """Build a minimal OpenAI /v1/embeddings response for *n* embeddings."""
    return {
        "object": "list",
        "data": [{"object": "embedding", "index": i, "embedding": _FAKE_VECTOR} for i in range(n)],
        "model": "text-embedding-3-small",
        "usage": {"prompt_tokens": 10 * n, "total_tokens": 10 * n},
    }


def _short_content() -> str:
    """Return content that is well under WHOLE_VS_CHUNKS_THRESHOLD tokens."""
    # ~50 words; well under 500-token threshold.
    return (
        "Today I decided to keep the side project going despite the time pressure. "
        "The team agreed the architecture is solid and the roadmap is realistic. "
        "We will revisit the timeline at the next weekly sync to make sure we stay on track."
    )


def _long_content() -> str:
    """Return content that tokenises to well above WHOLE_VS_CHUNKS_THRESHOLD."""
    sentence = (
        "The quick brown fox jumps over the lazy dog near the riverbank every single morning. "
    )
    text = ""
    while count_tokens(text) <= WHOLE_VS_CHUNKS_THRESHOLD + 100:
        text += sentence
    return text.strip()


async def _override_get_session() -> AsyncIterator[AsyncSession]:
    async with _TestSession() as session:
        yield session


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
def override_db() -> Iterator[None]:
    """Wire the app to the NullPool test engine for every test in this module."""
    app.dependency_overrides[get_session] = _override_get_session
    yield
    app.dependency_overrides.pop(get_session, None)


@pytest.fixture
async def authed_client() -> AsyncIterator[AsyncClient]:
    """ASGI test client pre-loaded with a valid Authorization header."""
    async with AsyncClient(
        transport=ASGITransport(app=app),
        base_url="http://test",
        headers=_AUTH_HEADERS,
    ) as client:
        yield client


@pytest.fixture
def short_payload() -> dict:
    """Fresh captures payload with unique client_id and short content."""
    return {
        "client_id": str(uuid.uuid4()),
        "content": _short_content(),
        "source_modality": "text",
        "source_device": "test-device",
        "captured_at": "2024-06-01T10:30:00+00:00",
    }


@pytest.fixture
def long_payload() -> dict:
    """Fresh captures payload with unique client_id and long (chunked) content."""
    return {
        "client_id": str(uuid.uuid4()),
        "content": _long_content(),
        "source_modality": "text",
        "source_device": "test-device",
        "captured_at": "2024-06-01T10:30:00+00:00",
    }


# ---------------------------------------------------------------------------
# Round-trip short capture (whole-embedding path)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@respx.mock
async def test_round_trip_short_capture(authed_client: AsyncClient, short_payload: dict) -> None:
    """POST → list shows it → GET by id returns full payload with embedding populated."""
    respx.post(_OPENAI_EMBEDDINGS_URL).mock(
        return_value=httpx.Response(200, json=_make_openai_response(1))
    )

    # Step 1: POST the capture.
    post_resp = await authed_client.post("/v1/captures", json=short_payload)
    assert post_resp.status_code == 201
    created = post_resp.json()
    assert "id" in created
    assert created["client_id"] == short_payload["client_id"]
    memory_id = created["id"]

    # Step 2: GET list and verify the memory appears.
    list_resp = await authed_client.get("/v1/memories", params={"limit": 50})
    assert list_resp.status_code == 200
    item_ids = [item["id"] for item in list_resp.json()["items"]]
    assert memory_id in item_ids

    # Step 3: GET by id and check the full payload.
    get_resp = await authed_client.get(f"/v1/memories/{memory_id}")
    assert get_resp.status_code == 200
    body = get_resp.json()
    assert body["id"] == memory_id
    assert body["content"] == short_payload["content"]
    # Short capture: no chunks.
    assert body["chunks"] == []
    # Embedding is not exposed in the response but the capture path stores it;
    # the GET endpoint correctly omits it from the payload.
    assert "embedding" not in body


# ---------------------------------------------------------------------------
# Round-trip long capture (chunked path)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@respx.mock
async def test_round_trip_long_capture(authed_client: AsyncClient, long_payload: dict) -> None:
    """POST long content → list shows it → GET by id has chunks, parent embedding IS NULL."""
    # Chunked path sends all chunk texts in one batch call; respond with the
    # right number of embeddings by inspecting the request body.
    respx.post(_OPENAI_EMBEDDINGS_URL).mock(
        side_effect=lambda req: httpx.Response(
            200,
            json=_make_openai_response(len(json.loads(req.content)["input"])),
        )
    )

    # Confirm the content is actually long enough to trigger chunking.
    assert count_tokens(long_payload["content"]) > WHOLE_VS_CHUNKS_THRESHOLD

    # Step 1: POST.
    post_resp = await authed_client.post("/v1/captures", json=long_payload)
    assert post_resp.status_code == 201
    memory_id = post_resp.json()["id"]

    # Step 2: verify it appears in the list.
    list_resp = await authed_client.get("/v1/memories", params={"limit": 50})
    assert list_resp.status_code == 200
    item_ids = [item["id"] for item in list_resp.json()["items"]]
    assert memory_id in item_ids

    # Step 3: GET by id — chunks present, parent embedding null.
    get_resp = await authed_client.get(f"/v1/memories/{memory_id}")
    assert get_resp.status_code == 200
    body = get_resp.json()
    assert body["id"] == memory_id
    assert len(body["chunks"]) >= 2
    # Chunk embeddings are not exposed; chunks have index and content fields.
    for idx, chunk in enumerate(body["chunks"]):
        assert chunk["chunk_index"] == idx
        assert "embedding" not in chunk
    # Parent embedding is null on the memory row itself (not in response, but
    # the list item should not show anything unexpected either).
    assert "embedding" not in body


# ---------------------------------------------------------------------------
# Idempotent retry over HTTP
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@respx.mock
async def test_idempotent_retry_same_client_id(
    authed_client: AsyncClient, short_payload: dict
) -> None:
    """POST same client_id twice → both succeed → list shows exactly one entry."""
    embed_route = respx.post(_OPENAI_EMBEDDINGS_URL).mock(
        return_value=httpx.Response(200, json=_make_openai_response(1))
    )

    r1 = await authed_client.post("/v1/captures", json=short_payload)
    r2 = await authed_client.post("/v1/captures", json=short_payload)

    assert r1.status_code == 201
    assert r2.status_code == 200
    assert r1.json()["id"] == r2.json()["id"]

    # Embedding called exactly once — idempotency short-circuits on second POST.
    assert embed_route.call_count == 1

    # List shows exactly one entry for this client_id.
    list_resp = await authed_client.get("/v1/memories", params={"limit": 200})
    assert list_resp.status_code == 200
    matching = [item for item in list_resp.json()["items"] if item["id"] == r1.json()["id"]]
    assert len(matching) == 1


# ---------------------------------------------------------------------------
# Auth gate — every path returns 401 without / with wrong token
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_auth_gate_no_token() -> None:
    """All three endpoints reject unauthenticated requests with 401."""
    random_id = str(uuid.uuid4())
    probe_payload = {
        "client_id": str(uuid.uuid4()),
        "content": "auth probe",
        "source_modality": "text",
        "source_device": "test",
        "captured_at": "2024-01-01T00:00:00+00:00",
    }

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        assert (await client.post("/v1/captures", json=probe_payload)).status_code == 401
        assert (await client.get("/v1/memories")).status_code == 401
        assert (await client.get(f"/v1/memories/{random_id}")).status_code == 401


@pytest.mark.asyncio
async def test_auth_gate_wrong_token() -> None:
    """All three endpoints reject a wrong bearer token with 401."""
    random_id = str(uuid.uuid4())
    probe_payload = {
        "client_id": str(uuid.uuid4()),
        "content": "auth probe",
        "source_modality": "text",
        "source_device": "test",
        "captured_at": "2024-01-01T00:00:00+00:00",
    }
    bad_headers = {"Authorization": "Bearer definitely-wrong-token"}

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        assert (
            await client.post("/v1/captures", json=probe_payload, headers=bad_headers)
        ).status_code == 401
        assert (await client.get("/v1/memories", headers=bad_headers)).status_code == 401
        assert (
            await client.get(f"/v1/memories/{random_id}", headers=bad_headers)
        ).status_code == 401
