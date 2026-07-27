# US-0001 — Add /health endpoint

> **Status:** completed | **Lane:** tiny | **Agent:** sdlc-backend-engineer

## Acceptance Criteria
- [x] GET /health returns `{"status":"ok","timestamp":"..."}` 
- [x] pytest exits 0
- [x] Response content-type is application/json

## Verification
- verify_cmd: `cd projects/fastapi-health && .venv/Scripts/python.exe -m pytest tests/ -x`
- Gate evidence: `artifacts/US-0001/verify-output.txt`
- SHA256: see artifacts/US-0001/evidence.sha256

## Edge Cases
- [x] Timestamp is ISO-8601 UTC format
- [x] Non-existent endpoint returns 404
- [x] Response headers include application/json

## Assumptions
- A1: No authentication required for health check
- A2: Port 8000 is available
