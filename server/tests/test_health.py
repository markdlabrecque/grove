import pytest
from httpx import ASGITransport, AsyncClient


@pytest.mark.asyncio
async def test_healthz_returns_ok() -> None:
    from grove.main import app

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/healthz")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}
