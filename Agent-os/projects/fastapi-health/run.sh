#!/usr/bin/env bash
# run.sh — start FastAPI health service for testing
# Usage: ./run.sh [port]

PORT="${1:-8000}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Starting FastAPI health server on port $PORT..."
cd "$SCRIPT_DIR"
uv run uvicorn main:app --host 0.0.0.0 --port "$PORT" &
PID=$!
echo "Server PID: $PID"
echo "Health check URL: http://localhost:$PORT/health"

# Wait for server to be ready
for i in $(seq 1 10); do
    sleep 1
    if curl -s "http://localhost:$PORT/health" > /dev/null 2>&1; then
        echo "Server ready."
        exit 0
    fi
    echo "Waiting... ($i/10)"
done

echo "Server failed to start within 10 seconds."
kill $PID 2>/dev/null
exit 1
