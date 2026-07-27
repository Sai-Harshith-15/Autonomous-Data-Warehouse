import pytest
from datetime import datetime
from httpx import AsyncClient, ASGITransport
from main import app

@pytest.mark.asyncio
async def test_health_returns_ok():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/health")
    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    assert "timestamp" in body
    datetime.fromisoformat(body["timestamp"])

@pytest.mark.asyncio
async def test_health_content_type():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/health")
    assert response.status_code == 200
    assert response.headers["content-type"] == "application/json"

@pytest.mark.asyncio
async def test_root_redirects_or_404():
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/")
    assert response.status_code == 404
