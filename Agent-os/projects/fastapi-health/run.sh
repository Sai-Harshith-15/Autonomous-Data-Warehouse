#!/usr/bin/env bash

PORT="${1:-8000}"

cd "$(dirname "$0")"

uv run uvicorn main:app --host 0.0.0.0 --port "$PORT" &

elapsed=0
while [ "$elapsed" -lt 10 ]; do
  if curl -s "http://localhost:${PORT}/health" > /dev/null 2>&1; then
    echo "Server is up and running on port $PORT"
    exit 0
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done

echo "Server failed to start within 10 seconds on port $PORT"
exit 1
