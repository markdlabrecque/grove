from __future__ import annotations

import os

import pytest
from httpx import ASGITransport, AsyncClient

# Read the token the same way the app does so tests work both locally
# (where conftest.py seeds a default) and in Docker (where BEARER_TOKEN
# is injected from docker-compose env).
CORRECT_TOKEN = os.environ.get("BEARER_TOKEN", "test-token")

# Use a minimal valid captures payload as the probe for auth tests.
_PROBE_PAYLOAD = {
    "client_id": "00000000-0000-0000-0000-000000000001",
    "content": "auth probe",
    "source_modality": "text",
    "source_device": "test",
    "captured_at": "2024-01-01T00:00:00+00:00",
}


@pytest.mark.asyncio
async def test_captures_no_auth_header_returns_401() -> None:
    from oracle.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/v1/captures", json=_PROBE_PAYLOAD)

    assert response.status_code == 401


@pytest.mark.asyncio
async def test_captures_wrong_token_returns_401() -> None:
    from oracle.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post(
            "/v1/captures",
            json=_PROBE_PAYLOAD,
            headers={"Authorization": "Bearer wrong-token"},
        )

    assert response.status_code == 401


@pytest.mark.asyncio
async def test_captures_basic_scheme_returns_401() -> None:
    from oracle.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post(
            "/v1/captures",
            json=_PROBE_PAYLOAD,
            headers={"Authorization": "Basic dXNlcjpwYXNz"},
        )

    assert response.status_code == 401


@pytest.mark.asyncio
async def test_healthz_remains_public() -> None:
    """Health check must not require auth — it's called by the load balancer."""
    from oracle.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/healthz")

    assert response.status_code == 200
