from __future__ import annotations

import os

import pytest
from httpx import ASGITransport, AsyncClient

# Read the token the same way the app does so tests work both locally
# (where conftest.py seeds a default) and in Docker (where BEARER_TOKEN
# is injected from docker-compose env).
CORRECT_TOKEN = os.environ.get("BEARER_TOKEN", "test-token")


@pytest.mark.asyncio
async def test_ping_no_auth_header_returns_401() -> None:
    from oracle.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/v1/ping")

    assert response.status_code == 401


@pytest.mark.asyncio
async def test_ping_wrong_token_returns_401() -> None:
    from oracle.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/v1/ping", headers={"Authorization": "Bearer wrong-token"})

    assert response.status_code == 401


@pytest.mark.asyncio
async def test_ping_basic_scheme_returns_401() -> None:
    from oracle.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/v1/ping", headers={"Authorization": "Basic dXNlcjpwYXNz"})

    assert response.status_code == 401


@pytest.mark.asyncio
async def test_ping_correct_token_returns_200() -> None:
    from oracle.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get(
            "/v1/ping", headers={"Authorization": f"Bearer {CORRECT_TOKEN}"}
        )

    assert response.status_code == 200
    assert response.json() == {"status": "pong"}


@pytest.mark.asyncio
async def test_healthz_remains_public() -> None:
    """Health check must not require auth — it's called by the load balancer."""
    from oracle.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/healthz")

    assert response.status_code == 200
