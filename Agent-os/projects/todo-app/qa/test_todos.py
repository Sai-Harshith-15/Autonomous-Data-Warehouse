Looking at the task, I need to write pytest tests for a FastAPI todo API. Let me first check if the main.py exists to understand the API structure.

```python
import pytest
import httpx
from httpx import ASGITransport

# Import the FastAPI app from main.py in the same project directory
import sys
import os

# Ensure the project root is on the path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from main import app

@pytest.fixture
async def client():
    transport = ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://testserver") as ac:
        yield ac

@pytest.fixture(autouse=True)
async def _clear_todos():
    """Reset todo state before each test so tests are isolated."""
    # Try to clear any in-memory store if accessible
    if hasattr(app, "state") and hasattr(app.state, "todos"):
        app.state.todos.clear()
    yield
    # Also attempt cleanup via the attribute approach after test
    if hasattr(app, "state") and hasattr(app.state, "todos"):
        app.state.todos.clear()

# ---------- helpers ----------

async def create_todo(client: httpx.AsyncClient, title: str = "Test todo") -> dict:
    """Helper to create a todo and return the response JSON."""
    resp = await client.post("/todos", json={"title": title})
    assert resp.status_code == 201
    return resp.json()

# ---------- tests ----------

@pytest.mark.anyio
async def test_create_todo(client: httpx.AsyncClient):
    """POST /todos returns 201 with id, title, and done fields."""
    payload = {"title": "Buy groceries"}
    resp = await client.post("/todos", json=payload)

    assert resp.status_code == 201
    body = resp.json()
    assert "id" in body
    assert body["title"] == "Buy groceries"
    assert "done" in body
    assert body["done"] is False

@pytest.mark.anyio
async def test_create_todo_returns_correct_types(client: httpx.AsyncClient):
    """Verify that returned field types are correct."""
    resp = await client.post("/todos", json={"title": "Typing check"})
    assert resp.status_code == 201
    body = resp.json()
    assert isinstance(body["id"], (int, str))
    assert isinstance(body["title"], str)
    assert isinstance(body["done"], bool)

@pytest.mark.anyio
async def test_list_todos(client: httpx.AsyncClient):
    """GET /todos returns a list of todos."""
    # Create a couple of todos first
    await create_todo(client, "First")
    await create_todo(client, "Second")

    resp = await client.get("/todos")
    assert resp.status_code == 200
    body = resp.json()
    assert isinstance(body, list)
    assert len(body) >= 2

    titles = [t["title"] for t in body]
    assert "First" in titles
    assert "Second" in titles

@pytest.mark.anyio
async def test_list_todos_empty(client: httpx.AsyncClient):
    """GET /todos on a fresh state returns an empty list (or at least a list)."""
    resp = await client.get("/todos")
    assert resp.status_code == 200
    body = resp.json()
    assert isinstance(body, list)

@pytest.mark.anyio
async def test_update_todo(client: httpx.AsyncClient):
    """PATCH /todos/{id} toggles the done field."""
    todo = await create_todo(client, "Toggle me")
    todo_id = todo["id"]

    assert todo["done"] is False

    # Mark as done
    resp = await client.patch(f"/todos/{todo_id}", json={"done": True})
    assert resp.status_code == 200
    body = resp.json()
    assert body["done"] is True
    assert body["id"] == todo_id

    # Toggle back
    resp = await client.patch(f"/todos/{todo_id}", json={"done": False})
    assert resp.status_code == 200
    body = resp.json()
    assert body["done"] is False

@pytest.mark.anyio
async def test_update_todo_title(client: httpx.AsyncClient):
    """PATCH /todos/{id} can also update the title if supported."""
    todo = await create_todo(client, "Old title")
    todo_id = todo["id"]

    resp = await client.patch(f"/todos/{todo_id}", json={"title": "New title"})
    # Accept 200 if title update is supported, otherwise just ensure no 500
    assert resp.status_code in (200, 422)
    if resp.status_code == 200:
        assert resp.json()["title"] == "New title"

@pytest.mark.anyio
async def test_delete_todo(client: httpx.AsyncClient):
    """DELETE /todos/{id} removes the todo."""
    todo = await create_todo(client, "Delete me")
    todo_id = todo["id"]

    # Delete it
    resp = await client.delete(f"/todos/{todo_id}")
    assert resp.status_code in (200, 204)

    # Verify it's gone
    resp = await client.get(f"/todos/{todo_id}")
    assert resp.status_code == 404

@pytest.mark.anyio
async def test_delete_todo_idempotent(client: httpx.AsyncClient):
    """DELETE on an already-deleted todo returns 404."""
    todo = await create_todo(client, "Delete twice")
    todo_id = todo["id"]

    resp = await client.delete(f"/todos/{todo_id}")
    assert resp.status_code in (200, 204)

    resp = await client.delete(f"/todos/{todo_id}")
    assert resp.status_code == 404

@pytest.mark.anyio
async def test_404_on_missing(client: httpx.AsyncClient):
    """GET /todos/{unknown_id} returns 404 for a non-existent todo."""
    # Use an ID that is extremely unlikely to exist
    missing_id = 999999
    resp = await client.get(f"/todos/{missing_id}")
    assert resp.status_code == 404

@pytest.mark.anyio
async def test_404_on_missing_patch(client: httpx.AsyncClient):
    """PATCH /todos/{unknown_id} returns 404 for a non-existent todo."""
    resp = await client.patch("/todos/999999", json={"done": True})
    assert resp.status_code == 404

@pytest.mark.anyio
async def test_cors_headers(client: httpx.AsyncClient):
    """Response includes CORS header access-control-allow-origin."""
    # Send a preflight OPTIONS request
    resp = await client.options(
        "/todos",
        headers={
            "Origin": "http://localhost:3000",
            "Access-Control-Request-Method": "GET",
        },
    )
    # The CORS middleware should respond with the allow-origin header
    # Check on both OPTIONS and a normal GET
    allow_origin = resp.headers.get("access-control-allow-origin")

    if allow_origin is None:
        # Some CORS configs only set headers on actual requests, try GET
        resp = await client.get(
            "/todos",
            headers={"Origin": "http://localhost:3000"},
        )
        allow_origin = resp.headers.get("access-control-allow-origin")

    assert allow_origin is not None, (
        "Expected 'access-control-allow-origin' header in response. "
        f"Got headers: {dict(resp.headers)}"
    )
    assert allow_origin in ("*", "http://localhost:3000")

@pytest.mark.anyio
async def test_get_single_todo(client: httpx.AsyncClient):
    """GET /todos/{id} returns the specific todo."""
    todo = await create_todo(client, "Specific todo")
    todo_id = todo["id"]

    resp = await client.get(f"/todos/{todo_id}")
    assert resp.status_code == 200
    body = resp.json()
    assert body["id"] == todo_id
    assert body["title"] == "Specific todo"
    assert body["done"] is False
