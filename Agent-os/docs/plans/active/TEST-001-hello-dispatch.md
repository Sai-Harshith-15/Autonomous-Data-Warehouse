---
schema_version: 1
plan_id: TEST-001
title: "Hello World dispatch test"
status: active
lane: tiny
verify_cmd: "python /d/GitRepo/Autonomous-Data-Warehouse/Agent-os/projects/hello-test/hello.py 2>&1 | grep -q 'hello from dispatch'"
acceptance:
  - "hello.py prints 'hello from dispatch'"
owner_agent: sdlc-backend-engineer
model: opencode-go/deepseek-v4-pro
depends_on: []
created: 2026-07-27
---

# Goal

Create a file `projects/hello-test/hello.py` containing exactly:
```python
print("hello from dispatch")
```

## Stories

- [ ] S1 — Create projects/hello-test/ directory
- [ ] S2 — Write hello.py with the exact content above

## Context

This is a minimal smoke test for the factory dispatch pipeline. No dependencies, no framework, just a standalone Python script.
