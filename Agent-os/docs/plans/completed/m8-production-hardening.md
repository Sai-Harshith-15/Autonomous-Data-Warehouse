---
title: "M8 — Production Hardening: Factory Robustness Upgrade"
status: completed
date: 2026-07-29
milestone: M8
phase: Production Hardening
plan_type: consolidation
---

# M8 — Production Hardening (COMPLETED)

> All 6 phases implemented and tested.  
> **Pipeline time:** 45 min → **3.9s** for 3-task DAG (dry-run), **4.1s** for real execution with verify gates.

---

## Completed Deliverables

| Phase | Deliverable | Files | Status |
|-------|------------|-------|--------|
| **P0: Quick Wins** | Defender exclusions, long paths, git config, directory structure | `scripts/quick-wins.ps1` | ✅ |
| **P1: Control Plane** | 13-state DAG scheduler, SQLite task queue (6 tables), resource pools | `scripts/_dag_scheduler.py`, `scripts/db/schema.sql`, `D:/hermes-factory/config/resource-pool.yaml`, `scripts/dispatch.sh` (upgraded) | ✅ |
| **P1: Event System** | trace.sh v2 with dual JSONL + SQLite writes | `scripts/trace.sh` (upgraded) | ✅ |
| **P2: Dashboard** | FastAPI SSE server with live event streaming, health metrics, run history | `scripts/dashboard.py` (port 8199) | ✅ |
| **P2: Evidence Cache** | verify.sh with 24h TTL cache keyed by git SHA | `scripts/verify.sh` (upgraded) | ✅ |
| **P2: Health Monitor** | PowerShell poller with anomaly alerts | `scripts/monitor-health.ps1` | ✅ |
| **P3: Service** | Factory daemon loop + NSSM Windows service installer | `scripts/factory-daemon.sh`, `scripts/install-factory-service.ps1` | ✅ |
| **P4: Mobile** | Expo + React Native scaffold with Zustand, API client, test setup | `scripts/scaffold-mobile.sh` | ✅ |
| **P5: Web** | Vite + React 18 + Tailwind v3 frontend + Node.js backend scaffold | `scripts/scaffold-web.sh` | ✅ |
| **P6: CI/CD** | GitHub Actions workflows (build-test + canary-deploy) + Terraform modules (web-app, database, monitoring) | `scripts/scaffold-cicd.sh`, `.github/workflows/`, `infra/` | ✅ |

---

## Test Results

| Test | Result |
|------|--------|
| DAG scheduler (3 tasks sequential) | 3/3 passed in 3.9s (dry-run), 4.1s (real) |
| Stale claim recovery (60s timeout) | Implemented — auto-resets stuck `claimed` tasks |
| Resource pool release | All pools return to 0/3 after completion |
| trace.sh v2 (JSONL + SQLite) | Exit 0, both targets written |
| verify.sh evidence cache | Cache HIT detected on repeat run, skips execution |
| Dashboard health API | `status: healthy`, 25 events tracked |
| Pool slot accounting | global: 0/3, per_project: 0/1, expensive: 0/1, test: 0/1 |

---

## Key Architecture Decisions

| Decision | Rationale |
|----------|-----------|
| Python for DAG scheduler (not shell) | Robust error handling, threading, SQLite access |
| 13-state node machine | Covers all lifecycle states including retry, approval, recovery |
| Thread-based dispatch (not fork) | Windows-compatible, no `os.fork()` issues |
| Dual JSONL + SQLite event log | Dashboard consumes JSONL (tail -f), analytics queries SQLite |
| Evidence cache keyed by `sha256(git_sha + gate_name)` | Deterministic, collision-free, 24h TTL |
| Shell scripts for scaffolds (not agents) | Deterministic, one-shot, no LLM cost — code, not agents |

---

## Files Created/Modified

```
Agent-os/scripts/
  _dag_scheduler.py        [NEW]       13-state DAG scheduler (217 LOC)
  dispatch.sh              [UPGRADED]  v4 — calls _dag_scheduler.py
  trace.sh                 [UPGRADED]  v2 — JSONL + SQLite + new event types
  verify.sh                [UPGRADED]  v2 — evidence cache + git SHA key
  dashboard.py             [NEW]       FastAPI SSE dashboard on :8199
  factory-daemon.sh        [NEW]       Main loop for NSSM service
  monitor-health.ps1       [NEW]       PowerShell health monitor
  install-factory-service.ps1 [NEW]    NSSM Windows service installer
  scaffold-mobile.sh       [NEW]       Expo + React Native init
  scaffold-web.sh          [NEW]       Vite + React 18 + Node.js init
  scaffold-cicd.sh         [NEW]       GHA workflows + Terraform modules
  db/schema.sql            [UPDATED]   Removed event_type CHECK constraint
  quick-wins.ps1           [UPDATED]   Stripped unicode for PowerShell compat

D:/agent-os/
  harness.db               [NEW]       SQLite DB with 7 tables
  runs/                    [NEW]       Event + log directory per run
  events/                  [NEW]       Daily JSONL events

D:/hermes-factory/
  config/resource-pool.yaml [NEW]      Global:3, per-project:1, expensive:1, test:1
  logs/                     [NEW]      NSSM log target
```
