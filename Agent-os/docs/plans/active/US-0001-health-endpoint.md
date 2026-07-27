---
schema_version: 1
plan_id: US-0001
title: "Add /health endpoint to FastAPI app"
status: active
lane: tiny
verify_cmd: "cd projects/fastapi-health && .venv/Scripts/python.exe -m pytest tests/ -x --tb=short -q"
verify_url: "curl -sS -m 3 http://localhost:8000/health | python -c \"import sys,json; d=json.load(sys.stdin); assert d['status']=='ok'\""
acceptance:
  - "pytest exits 0 with all tests passing"
  - "curl http://localhost:8000/health returns {\"status\":\"ok\",\"timestamp\":\"...\"}"
  - "At least 2 .py files under projects/fastapi-health/"
owner_agent: sdlc-backend-engineer
model: opencode-go/deepseek-v4-pro
depends_on: []
created: 2026-07-26
retry_count: 1
---

# Goal

Add a `/health` endpoint to a FastAPI application that returns JSON:
```json
{"status": "ok", "timestamp": "2026-07-26T22:00:00Z"}
```

## Stories

- [ ] S1 — Scaffold FastAPI app with `main.py`, `pyproject.toml`, and test skeleton
- [ ] S2 — Implement `/health` route that returns `{"status":"ok","timestamp":"..."}`
- [ ] S3 — Write `tests/test_health.py` with pytest + httpx
- [ ] S4 — Gate: pytest passes, curl returns expected JSON

## Context for dispatcher

- Repo root: `projects/fastapi-health/`
- Dependencies: `fastapi`, `uvicorn`, `httpx`, `pytest`
- ADR to honor: ADR-0001 (factory uses upstream harness, not PRD harness)
- Windows safety: use POSIX paths, no backslashes in file paths
- The verify_cmd includes `cd projects/fastapi-health &&` — agent must ensure that directory exists and contains a working project

## Constraints

- No external API calls
- No docker
- All paths repo-relative (`projects/fastapi-health/...`)
- Python 3.11+, uvicorn for server, httpx for test client

## Handoff

After dispatch, the producing agent writes:
- A handoff packet to `docs/stories/US-0001-handoff-agent-to-orch.md` with:
  - Decisions made
  - Constraints for next agent
  - Known unknowns
  - Files produced
