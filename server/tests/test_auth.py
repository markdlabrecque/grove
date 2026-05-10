from __future__ import annotations

from collections.abc import AsyncIterator

import pytest
from httpx import ASGITransport, AsyncClient

from oracle.core.config import settings

# oracle.main is imported at module level so Python's import cache makes this
# a single import regardless of how many tests run. conftest.py seeds the env
# vars (BEARER_TOKEN, DATABASE_URL, OPENAI_API_KEY) before this line executes.
from oracle.main import app

# Use the same token the app validates against, not a hardcoded value.
_AUTH_HEADERS = {"Authorization": f"Bearer {settings.bearer_token}"}

# Use a minimal valid captures payload as the probe for auth tests.
_PROBE_PAYLOAD = {
    "client_id": "00000000-0000-0000-0000-000000000001",
    "content": "auth probe",
    "source_modality": "text",
    "source_device": "test",
    "captured_at": "2024-01-01T00:00:00+00:00",
}


@pytest.fixture
async def client() -> AsyncIterator[AsyncClient]:
    """Shared ASGI test client for all auth tests."""
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as ac:
        yield ac


@pytest.mark.asyncio
async def test_captures_no_auth_header_returns_401(client: AsyncClient) -> None:
    response = await client.post("/v1/captures", json=_PROBE_PAYLOAD)
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_captures_wrong_token_returns_401(client: AsyncClient) -> None:
    response = await client.post(
        "/v1/captures",
        json=_PROBE_PAYLOAD,
        headers={"Authorization": "Bearer wrong-token"},
    )
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_captures_basic_scheme_returns_401(client: AsyncClient) -> None:
    response = await client.post(
        "/v1/captures",
        json=_PROBE_PAYLOAD,
        headers={"Authorization": "Basic dXNlcjpwYXNz"},
    )
    assert response.status_code == 401


@pytest.mark.asyncio
async def test_healthz_remains_public(client: AsyncClient) -> None:
    """Health check must not require auth — it's called by the load balancer."""
    response = await client.get("/healthz")
    assert response.status_code == 200
