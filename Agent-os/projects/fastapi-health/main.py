"""
FastAPI application with /health endpoint.
Part of AI Software Factory Milestone 1 — US-0001.
"""

from fastapi import FastAPI
from datetime import datetime, timezone


app = FastAPI(title="Health Check Service", version="0.1.0")


@app.get("/health")
async def health():
    """Returns service health status with current UTC timestamp."""
    return {
        "status": "ok",
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)
