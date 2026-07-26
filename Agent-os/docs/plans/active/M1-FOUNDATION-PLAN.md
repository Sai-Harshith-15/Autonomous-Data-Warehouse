# Milestone 1 — The Smallest Working Factory

> **Goal:** Prove Hermes can receive one feature request and ship it automatically.
> **Duration:** 2–3 weeks
> **Exit Criterion:** One real feature shipped through the factory with full evidence, zero human intervention after intake.

---

## What We Build (and Skip)

### Build

- [x] Repository with `.gitattributes` + `.gitignore` (Windows-safe)
- [x] Upstream repository-harness core installed
- [ ] `scripts/trace.sh` — append JSONL events to `events/YYYY-MM-DD.jsonl`
- [ ] `scripts/verify.sh` — run a story's verify command, record exit code
- [ ] `scripts/dispatch.sh` — route a task to an agent (DeepSeek V4 Pro)
- [ ] `scripts/feedback-loop.sh` — classify failure, route back
- [ ] `scripts/report.sh` — weekly rollup from events
- [ ] `docs/TOOL_REGISTRY.md` — MCP and tool registration
- [ ] First end-to-end: tiny feature → plan → agent → gate → trace

### Skip (Milestone 2+)

- ❌ SQLite harness.db
- ❌ Typed JSON task contracts (use plan files with YAML frontmatter)
- ❌ Multiple agents in parallel
- ❌ DAG scheduler
- ❌ Capability broker / sandbox tiers
- ❌ Provenance / replay engine
- ❌ Metrics dashboard
- ❌ Human approval CLI
- ❌ Security review gate
- ❌ Cost tracking

---

## Task Breakdown

### M1-T01 — Clone Harness Repos

**Status:** ✅ Complete
**Output:** `D:/GitRepo/coding_tools/{repository-harness, learn-harness-engineering, awesome-harness-engineering}`
**Test:** `ls -d /d/GitRepo/coding_tools/*/` shows 3 directories

### M1-T02 — Install Harness Core

**Status:** ✅ Complete
**Output:** `Agent-os/` has `AGENTS.md`, `docs/`, `.agents/`, `scripts/bin/harness-cli.exe`
**Test:** `./scripts/bin/harness-cli.exe doctor --json` → `healthy: true`

### M1-T03 — Reconcile Command Surface

**Status:** ✅ Complete (ADR-0001)
**Output:** `docs/decisions/ADR-0001-harness-upstream-vs-prd.md`
**Test:** ADR exists and documents the gap

### M1-T04 — Create Event Log Infrastructure

**Goal:** `events/` directory + `scripts/trace.sh` that appends JSONL
**Owner:** DeepSeek V4 Pro
**Inputs:** PRD §22.1 event schema
**Outputs:**
- `events/.gitkeep`
- `scripts/trace.sh` — accepts `--summary`, `--outcome`, `--task-id`, `--story-id`, appends JSON line
- Test: `scripts/trace.sh --summary "test" --outcome success` creates valid JSONL

**DoD:**
- [ ] `trace.sh` executable, accepts named args
- [ ] Writes to `events/YYYY-MM-DD.jsonl`
- [ ] JSON has `schema_version`, `ts`, `run_id`, `task_id`, `story_id`, `actor`, `event`, `outcome`
- [ ] `run_id` generated if not provided: `R-YYYY-MM-DD-NNN` (increments per day)
- [ ] `actor` defaults to `orchestrator`

### M1-T05 — Create Verification Script

**Goal:** `scripts/verify.sh` runs a story's proof command and records the result
**Owner:** DeepSeek V4 Pro
**Inputs:** Story file path (e.g., `docs/plans/active/US-0001-health-endpoint.md`)
**Outputs:**
- `scripts/verify.sh` — reads `verify_cmd` from plan frontmatter, runs it, records exit code + output to `artifacts/<story-id>/`
- Test: create a story with `verify_cmd: "echo hello"` → `verify.sh` runs it, writes `artifacts/US-0001/verify-output.txt`, returns exit 0

**DoD:**
- [ ] Reads plan file, extracts `verify_cmd` from YAML frontmatter
- [ ] Runs command, captures stdout+stderr to artifact
- [ ] Returns command's exit code
- [ ] Calls `trace.sh` with outcome
- [ ] Writes evidence hash (sha256 of output) to `artifacts/<story-id>/evidence.sha256`

### M1-T06 — Create Dispatch Script

**Goal:** `scripts/dispatch.sh` routes a task to DeepSeek V4 Pro via OpenCode Go
**Owner:** DeepSeek V4 Pro
**Inputs:** Plan file path, task description
**Outputs:**
- `scripts/dispatch.sh` — reads plan, constructs prompt, calls `opencode` CLI with DeepSeek V4 Pro model
- Test: `dispatch.sh --plan docs/plans/active/test.md --task "Add a /health endpoint"` produces code changes

**DoD:**
- [ ] Reads plan file, extracts goal + context
- [ ] Constructs agent prompt with: goal, constraints, file tree, existing code
- [ ] Calls `opencode` with model `deepseek-v4-pro` (or configured model)
- [ ] Captures agent output to `artifacts/<task-id>/agent-output.md`
- [ ] Calls `trace.sh` with dispatch event

### M1-T07 — Create Feedback Loop Script

**Goal:** `scripts/feedback-loop.sh` classifies failures and routes back
**Owner:** DeepSeek V4 Pro
**Inputs:** Failed task ID, failure output
**Outputs:**
- `scripts/feedback-loop.sh` — reads failure, classifies per §15.1, decides retry/route-back/abort
- Test: deliberately fail a verify → feedback-loop classifies as `TEST_FAILURE` → routes back to dispatch

**DoD:**
- [ ] Reads failure output (exit code, stderr)
- [ ] Classifies: TRANSIENT / TEST_FAILURE / CONTRACT_VIOLATION / SPEC_AMBIGUITY / ENVIRONMENT
- [ ] For TEST_FAILURE: re-dispatches to same agent with failure context
- [ ] For SPEC_AMBIGUITY: flags plan file, requires human edit
- [ ] For CONTRACT_VIOLATION: aborts, requires human intervention
- [ ] Calls `trace.sh` with classification event

### M1-T08 — Create Tool Registry

**Goal:** `docs/TOOL_REGISTRY.md` listing all tools and their capabilities
**Owner:** Kimi K3 (planning)
**Inputs:** PRD §9.1 MCP server registry, §4.2 coding agents
**Outputs:** `docs/TOOL_REGISTRY.md` with tables for MCP servers, agents, deterministic tools

**DoD:**
- [ ] Table: name, kind (mcp/cli/agent), capability, command, status, responsibility
- [ ] 5 MCP servers listed
- [ ] 4 coding agents listed (Claude Code, Codex, OpenCode, DeepSeek)
- [ ] Deterministic tools listed (git, pytest, etc.)

### M1-T09 — Create Report Script

**Goal:** `scripts/report.sh` generates weekly rollup
**Owner:** DeepSeek V4 Pro
**Inputs:** `events/*.jsonl`
**Outputs:**
- `scripts/report.sh` — reads events, produces summary: tasks dispatched, gates passed/failed, success rate
- Test: run after a few traces → produces readable summary

**DoD:**
- [ ] Reads all `events/*.jsonl` files
- [ ] Counts events by type, outcome
- [ ] Computes: total tasks, success rate, failure classes
- [ ] Outputs markdown table
- [ ] Appends to `docs/reports/weekly-YYYY-WNN.md`

### M1-T10 — First End-to-End Feature

**Goal:** Ship a real feature through the factory
**Feature:** "Add a `/health` endpoint to a Python FastAPI app that returns `{"status": "ok", "timestamp": "..."}`"
**Owner:** DeepSeek V4 Pro (implementation) + Kimi K3 (plan review)
**Inputs:** Feature request
**Outputs:**
- `docs/plans/active/US-0001-health-endpoint.md` — plan with verify_cmd
- `projects/fastapi-health/` — minimal FastAPI app with health endpoint
- `projects/fastapi-health/tests/test_health.py` — pytest test
- Gate evidence: pytest output, coverage

**DoD:**
- [ ] Plan file created with: goal, stories, verify_cmd, acceptance criteria
- [ ] Dispatch to DeepSeek V4 Pro produces working code
- [ ] `verify.sh` runs pytest, exit 0
- [ ] Evidence artifact stored
- [ ] `trace.sh` records all events
- [ ] Feature works: `curl localhost:8000/health` returns JSON

### M1-T11 — Deliberate Failure Test

**Goal:** Prove the feedback loop works
**Owner:** DeepSeek V4 Pro
**Method:** Break the health endpoint test (change assertion), run verify → feedback-loop → dispatch fix → verify passes

**DoD:**
- [ ] Test fails (assertion broken)
- [ ] `feedback-loop.sh` classifies as TEST_FAILURE
- [ ] Re-dispatch fixes the code
- [ ] `verify.sh` passes on second attempt
- [ ] All events traced

### M1-T12 — Documentation and Handoff

**Goal:** Document what was built, how to resume
**Owner:** Kimi K3
**Outputs:**
- `docs/MILESTONE-1-RETROSPECTIVE.md` — what worked, what didn't, lessons
- `docs/NEXT-STEPS.md` — Milestone 2 preview
- Updated `README.md` in `Agent-os/` — how to use the factory

**DoD:**
- [ ] Retrospective lists: tasks completed, time taken, failures encountered, decisions made
- [ ] Next steps clearly states what M2 adds (backend + frontend + QA agents)
- [ ] README has quickstart: "how to ship a feature"

---

## Dependency Graph

```
M1-T01 (clone repos) ──→ M1-T02 (install harness) ──→ M1-T03 (ADR-0001)
                                                           │
                                                           ▼
M1-T04 (trace.sh) ←── M1-T05 (verify.sh) ←── M1-T06 (dispatch.sh) ←── M1-T07 (feedback-loop.sh)
     │                    │                      │                      │
     └────────────────────┴──────────────────────┴──────────────────────┘
                                    │
                                    ▼
                           M1-T08 (tool registry)
                                    │
                                    ▼
                           M1-T09 (report.sh)
                                    │
                                    ▼
                           M1-T10 (first feature)
                                    │
                                    ▼
                           M1-T11 (failure test)
                                    │
                                    ▼
                           M1-T12 (retrospective)
```

**Critical path:** T01 → T02 → T03 → T04 → T05 → T06 → T07 → T10 → T11 → T12

**Parallelizable:** T08 (tool registry) and T09 (report.sh) can be built anytime after T04.

---

## Model Assignment

| Task | Model | Why |
|------|-------|-----|
| T04–T07, T09–T11 | DeepSeek V4 Pro | Code generation, script writing |
| T08, T12 | Kimi K3 | Planning, documentation, retrospective |

---

## Session Handoff Protocol

Each work session ends with:

1. **Update this plan** — mark tasks complete, add notes
2. **Commit all changes** — git commit with conventional message
3. **Write session summary** — append to `docs/sessions/YYYY-MM-DD-session-N.md`:
   - What was done
   - What's next
   - Any blockers
   - Files changed
4. **Next session starts by reading** — this plan + last session summary

---

## Current Session

- **Session 1:** 2026-07-26 — T01, T02, T03 complete. ADR-0001 written. Next: T04 (trace.sh).

---

*Plan maintained by SDLC Orchestrator. Update after every task.*
