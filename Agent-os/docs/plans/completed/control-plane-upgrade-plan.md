# AI Software Factory — Production Readiness Upgrade Plan

**Status:** Proposed  
**Target:** M8 — Production Hardening  
**Platform:** Windows 10 + git-bash (MSYS2/MINGW64)  
**Repository:** `D:/GitRepo/Autonomous-Data-Warehouse/Agent-os/`  
**Factory Path:** `D:/hermes-factory/`  
**Agent Work Path:** `D:/agent-os/work/`  
**Artifact Path:** `D:/agent-os/artifacts/`  
**Date:** 2026-07-28

---

## Table of Contents

1. [DAG Scheduler Upgrade — Multi-Level Scheduler with Full Node State Machine](#1-dag-scheduler-upgrade)
2. [SQLite Task Queue Schema — Tasks + Events + Runs](#2-sqlite-task-queue-schema)
3. [Resource Pool YAML Configuration](#3-resource-pool-yaml-configuration)
4. [Windows Defender Exclusion Directories](#4-windows-defender-exclusion-directories)
5. [Evidence Caching Design — Git SHA + Gate Name Keyed, 24h TTL](#5-evidence-caching-design)
6. [NSSM Windows Service Wrapper for Hermes Factory Process](#6-nssm-windows-service-wrapper)

---

## 1. DAG Scheduler Upgrade

### Current State

`dispatch.sh` currently handles only DAG level 0 — nodes with an empty `depends_on` array. It dispatches them in parallel but never marks a node complete, never recalculates downstream readiness, and never transitions node states beyond the initial dispatch. The entire DAG collapses after the first wave.

### Target State

A **multi-level DAG scheduler** that maintains a **13-state node machine** and cycles through levels until all terminal nodes reach `succeeded` or `failed`.

### Node State Machine

```
                         ┌──────────────────────────────┐
                         │          PENDING              │
                         │  (not yet evaluated)          │
                         └──────────┬───────────────────┘
                                    │ all dependencies succeeded
                                    ▼
                         ┌──────────────────────────────┐
                         │          READY                │
                         │  (eligible for dispatch)      │
                         └──────────┬───────────────────┘
                                    │ claimed by scheduler
                                    ▼
                         ┌──────────────────────────────┐
                         │         CLAIMED               │
                         │  (slot reserved, dispatching) │
                         └──────────┬───────────────────┘
                                    │ dispatched to agent
                                    ▼
                         ┌──────────────────────────────┐
                         │         RUNNING               │
                         │  (agent executing)            │
                         └──┬───────┬──────────┬────────┘
                            │       │          │
                    exit 0  │  exit≠0│          │ timeout
                            ▼       ▼          ▼
                     ┌─────────┐ ┌────────┐ ┌──────────┐
                     │SUCCEEDED│ │RETRYING│ │  FAILED  │
                     │         │ │ retry< │ │          │
                     └─────────┘ │ max?   │ └──────────┘
                                 └───┬────┘
                               yes │   │ no
                                   ▼   ▼
                             ┌────────┐ ┌──────────┐
                             │ CLAIMED│ │  FAILED  │
                             │ (re-   │ │          │
                             │dispatch)│ └──────────┘
                             └────────┘
```

**Additional states:**
- **`blocked`** — one or more dependencies have failed; node cannot proceed. Automatically set when any dependency reaches `failed` or `cancelled`.
- **`cancelled`** — manually cancelled or circuit-breaker tripped. Propagates downstream to `blocked`.
- **`awaiting_approval`** — human gate required (sandbox T3 tasks). The scheduler pauses this node until `approve.sh` marks it approved or rejected.
- **`pending`** — initial state; not yet evaluated.
- **`ready`** — all dependencies succeeded; waiting for a resource slot.
- **`claimed`** — resource slot acquired; dispatch in progress.
- **`running`** — agent is executing the task.
- **`succeeded`** — agent exited 0, verification passed.
- **`failed`** — agent exited non-zero OR verification failed AND retries exhausted OR fatal class.
- **`retrying`** — retryable failure; retry count < max_retries.
- **`blocked`** — dependency failure cascaded.
- **`cancelled`** — manual or circuit-breaker cancellation.
- **`awaiting_approval`** — waiting for human approval gate.

### Scheduler Algorithm (`schedule.sh` rewrite)

```bash
#!/usr/bin/env bash
# schedule.sh — Multi-level DAG scheduler with full state machine
# Usage: ./schedule.sh <sqlite_db> <dag_json>
set -euo pipefail

DB="${1:?Usage: schedule.sh <sqlite_db> <dag_json>}"
DAG_JSON="${2:?}"
RUN_ID=$(python -c "import uuid; print(uuid.uuid4())[:8]")

# Phase 1: Load DAG into task_queue
python3 -c "
import json, sqlite3, sys

dag = json.load(open(sys.argv[1]))
db = sqlite3.connect(sys.argv[2])
db.execute('PRAGMA journal_mode=WAL;')
db.execute('PRAGMA busy_timeout=5000;')

for node in dag['nodes']:
    db.execute('''
        INSERT OR REPLACE INTO tasks
            (task_id, dag_id, run_id, depends_on, state, priority, retry_count, max_retries,
             owner_skill, sandbox_tier, model_id, task_timeout, created_at)
        VALUES (?, ?, ?, ?, 'pending', ?, 0, ?, ?, ?, ?, ?, datetime('now'))
    ''', (
        node['id'],
        dag.get('dag_id', 'default'),
        '$RUN_ID',
        json.dumps(node.get('depends_on', [])),
        node.get('priority', 0),
        node.get('max_retries', 2),
        node.get('owner_skill', ''),
        node.get('sandbox_tier', 'T1'),
        node.get('model_id', ''),
        node.get('timeout', 900)
    ))
db.commit()
print(f'Loaded {len(dag[\"nodes\"])} nodes into task queue')
" "$DAG_JSON" "$DB"
```

### State Transition Logic (core loop in `dag.sh`)

```python
#!/usr/bin/env python3
"""_dag_scheduler.py — Multi-level DAG scheduler, runs via schedule.sh"""
import json, sqlite3, os, sys, time, subprocess, hashlib

DB_PATH = sys.argv[1]
DAG_JSON = sys.argv[2]
MAX_SCHEDULE_ITERATIONS = 200

def get_conn():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("PRAGMA busy_timeout=5000;")
    return conn

def transition(task_id: str, new_state: str, reason: str = ""):
    conn = get_conn()
    conn.execute("""
        UPDATE tasks SET state=?, updated_at=datetime('now'), reason=?
        WHERE task_id=?
    """, (new_state, reason, task_id))
    conn.execute("""
        INSERT INTO events (task_id, run_id, event_type, old_state, new_state, payload)
        VALUES (?, ?, 'state_transition',
            (SELECT state FROM tasks WHERE task_id=?),
            ?, ?)
    """, (task_id, get_run_id(conn), task_id, new_state, reason))
    conn.commit()

def get_run_id(conn):
    row = conn.execute("SELECT DISTINCT run_id FROM tasks LIMIT 1").fetchone()
    return row["run_id"] if row else "unknown"

def evaluate_readiness(conn):
    """Find all PENDING nodes whose dependencies have all SUCCEEDED."""
    pending = conn.execute(
        "SELECT task_id, depends_on FROM tasks WHERE state = 'pending'"
    ).fetchall()
    ready = []
    for row in pending:
        deps = json.loads(row["depends_on"]) if row["depends_on"] else []
        if not deps:
            ready.append(row["task_id"])
            continue
        dep_states = conn.execute("""
            SELECT state FROM tasks WHERE task_id IN ({})
        """.format(",".join("?" * len(deps))), deps).fetchall()
        if all(d["state"] == "succeeded" for d in dep_states):
            ready.append(row["task_id"])
        elif any(d["state"] in ("failed", "cancelled") for d in dep_states):
            # Block this node — dependency failed
            transition(row["task_id"], "blocked",
                       f"Dependency {deps[dep_states.index(next(d for d in dep_states if d['state'] in ('failed','cancelled')))]} failed")
    return ready

def dispatch_task(task_id: str, conn):
    """Claim and dispatch a single task — returns True if dispatched."""
    task = conn.execute("SELECT * FROM tasks WHERE task_id=?", (task_id,)).fetchone()
    if not task or task["state"] != "pending":
        return False

    # Check resource pool capacity
    if not resource_pool_acquire(task, conn):
        return False  # Stay pending; retry on next cycle

    # Check sandbox tier — T3 needs human approval
    if task["sandbox_tier"] == "T3":
        transition(task_id, "awaiting_approval",
                   "T3 task — waiting for human approval gate")
        resource_pool_release(task, conn)
        return False

    transition(task_id, "claimed", "resource slot acquired")

    # Build contract and invoke OmniRoute / agent
    contract = build_contract(task, conn)
    agent_result = invoke_agent(contract, task)

    if agent_result["exit_code"] == 0:
        # Verify
        verify_ok = run_verification(task, conn)
        if verify_ok:
            transition(task_id, "succeeded", "agent completed + verification passed")
        else:
            handle_failure(task, conn, "VERIFICATION_FAILED")
    else:
        handle_failure(task, conn, agent_result.get("failure_class", "UNKNOWN"))

    resource_pool_release(task, conn)
    propagate_downstream(conn, task_id)
    return True

def handle_failure(task, conn, failure_class: str):
    """Check retry budget, then fail or retry."""
    if failure_class in ("CONTRACT_VIOLATION", "SPEC_AMBIGUITY", "SECURITY_FINDING"):
        # Non-retryable
        transition(task["task_id"], "failed",
                   f"Non-retryable: {failure_class}")
        return

    retries = task["retry_count"] + 1
    if retries >= task["max_retries"]:
        transition(task["task_id"], "failed",
                   f"Retries exhausted ({retries}/{task['max_retries']}): {failure_class}")
        return

    conn.execute("UPDATE tasks SET retry_count=? WHERE task_id=?",
                 (retries, task["task_id"]))
    transition(task["task_id"], "retrying",
               f"Retry {retries}/{task['max_retries']}: {failure_class}")

def propagate_downstream(conn, task_id: str):
    """When a task fails or is cancelled, block all downstream nodes."""
    task_state = conn.execute("SELECT state FROM tasks WHERE task_id=?",
                              (task_id,)).fetchone()["state"]
    if task_state not in ("failed", "cancelled"):
        return
    downstream = conn.execute(
        "SELECT task_id FROM tasks WHERE depends_on LIKE ?",
        (f"%{task_id}%",)
    ).fetchall()
    for d in downstream:
        if d["state"] in ("pending", "ready"):
            transition(d["task_id"], "blocked",
                       f"Upstream dependency {task_id} is {task_state}")

def main():
    conn = get_conn()
    run_id = get_run_id(conn)

    for iteration in range(MAX_SCHEDULE_ITERATIONS):
        ready_tasks = evaluate_readiness(conn)

        if not ready_tasks:
            # Check if any tasks are still running or pending
            active = conn.execute(
                "SELECT COUNT(*) as c FROM tasks WHERE state IN ('running','claimed','retrying','awaiting_approval','pending')"
            ).fetchone()["c"]
            if active == 0:
                print(f"[schedule] DAG complete — all terminal nodes resolved in {iteration} iterations")
                break
            else:
                time.sleep(2)
                continue

        for task_id in ready_tasks:
            dispatch_task(task_id, conn)

        time.sleep(1)

    # Final report
    states = conn.execute(
        "SELECT state, COUNT(*) as cnt FROM tasks WHERE run_id=? GROUP BY state",
        (run_id,)
    ).fetchall()
    print(f"[schedule] Final state distribution for run {run_id}:")
    for row in states:
        print(f"  {row['state']}: {row['cnt']}")

if __name__ == "__main__":
    main()
```

### Upgrade Path for Existing Scripts

| Script | Change Required |
|--------|----------------|
| `dispatch.sh` | Deprecated. Replace with `schedule.sh` call that reads the DAG and calls `_dag_scheduler.py`. |
| `schedule.sh` | Rewrite as the DAG scheduler entry point — calls `_dag_scheduler.py` in a loop. |
| `dag.sh` | Replace DAG construction with SQLite-backed DAG loading (nodes + edges table). |
| `checkpoint.sh` | Add `run_id` field to checkpoints. Serialize full task state snapshot. |
| `resume.sh` | Restore task states from checkpoint + rebuild `task_queue`. |
| `circuit-breaker.sh` | Read `tasks` table grouped by `failure_class`; halt run if ≥3 same-class in same run. |
| `feedback-loop.sh` | Write classified failures to `events` table with `failure_class` and `task_id`. |

---

## 2. SQLite Task Queue Schema

### Schema Design Rationale

Three separate tables for **tasks** (the unit of work), **events** (the audit trail), and **runs** (the grouping container). This separation gives:
- **Tasks**: Mutable state with retry counters and deadlines.
- **Events**: Immutable append-only log for traceability and replay.
- **Runs**: Top-level grouping so a single scheduler instance can manage multiple DAG runs.

### DDL

```sql
-- ============================================================
-- TASKS — The unit of work in the DAG
-- ============================================================
CREATE TABLE IF NOT EXISTS tasks (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id             TEXT    NOT NULL UNIQUE,          -- e.g. "T-2026-0042"
    dag_id              TEXT    NOT NULL DEFAULT 'default',
    run_id              TEXT    NOT NULL,                  -- FK to runs.run_id
    depends_on          TEXT    DEFAULT '[]',              -- JSON array of task_ids
    state               TEXT    NOT NULL DEFAULT 'pending' -- see state machine
                            CHECK(state IN (
                                'pending','ready','claimed','running',
                                'succeeded','failed','blocked','retrying',
                                'cancelled','awaiting_approval'
                            )),
    priority            INTEGER NOT NULL DEFAULT 0,       -- higher = more urgent
    retry_count         INTEGER NOT NULL DEFAULT 0,
    max_retries         INTEGER NOT NULL DEFAULT 2,
    failure_class       TEXT,                              -- from feedback-loop taxonomy
    failure_reason      TEXT,                              -- human-readable reason

    -- Contract fields
    owner_skill         TEXT,                              -- e.g. "sdlc-backend-engineer"
    sandbox_tier        TEXT NOT NULL DEFAULT 'T1'
                            CHECK(sandbox_tier IN ('T0','T1','T2','T3')),
    model_id            TEXT,                              -- e.g. "opencode-go/deepseek-v4-pro"
    story_id            TEXT,                              -- FK to story
    goal                TEXT,                              -- short description
    inputs_json         TEXT DEFAULT '[]',                  -- JSON array of paths
    outputs_json        TEXT DEFAULT '[]',                  -- JSON array of paths
    contract_hash       TEXT,                              -- SHA256 of full contract JSON

    -- Timing
    task_timeout        INTEGER NOT NULL DEFAULT 900,       -- seconds
    created_at          TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at          TEXT NOT NULL DEFAULT (datetime('now')),
    claimed_at          TEXT,                               -- when dispatched
    started_at          TEXT,                               -- when agent began
    completed_at        TEXT,                               -- when terminal state reached
    deadline_at         TEXT GENERATED ALWAYS AS (
                            datetime(created_at, '+' || task_timeout || ' seconds')
                        ) STORED,                           -- computed deadline

    -- Evidence (cache lookup)
    evidence_key        TEXT,                               -- git_sha + gate_name
    evidence_hash       TEXT,                               -- SHA256 of evidence artifact
    cached_hit          INTEGER DEFAULT 0                   -- 1 = satisfied from cache

    -- Indexes
    CREATE INDEX idx_tasks_run_id ON tasks(run_id);
    CREATE INDEX idx_tasks_state ON tasks(state);
    CREATE INDEX idx_tasks_depends ON tasks(dag_id, state);
    CREATE INDEX idx_tasks_evidence_key ON tasks(evidence_key) WHERE evidence_key IS NOT NULL;
);

-- ============================================================
-- EVENTS — Immutable append-only audit log
-- ============================================================
CREATE TABLE IF NOT EXISTS events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id        TEXT    NOT NULL UNIQUE,                -- UUID generated at write
    run_id          TEXT    NOT NULL,                       -- FK to runs.run_id
    task_id         TEXT,                                   -- FK to tasks.task_id (nullable for run-level events)
    event_type      TEXT    NOT NULL,                        -- see event types below
    old_state       TEXT,                                    -- previous task state
    new_state       TEXT,                                    -- current task state
    failure_class   TEXT,                                    -- from taxonomy
    payload         TEXT,                                    -- JSON blob with context
    agent_output    TEXT,                                    -- truncated agent stdout
    agent_exit_code INTEGER,
    duration_ms     INTEGER,                                 -- how long this event took
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),

    -- Indexes
    CREATE INDEX idx_events_run_id ON events(run_id);
    CREATE INDEX idx_events_task_id ON events(task_id);
    CREATE INDEX idx_events_type ON events(event_type);
    CREATE INDEX idx_events_created ON events(created_at);
);

-- Event types enum:
--   'run_started', 'run_completed', 'run_failed'
--   'dag_loaded', 'dag_complete'
--   'state_transition' (old_state → new_state)
--   'evidence_cached', 'evidence_cache_hit', 'evidence_cache_miss'
--   'resource_acquired', 'resource_released', 'resource_timeout'
--   'circuit_breaker_tripped'
--   'human_approval_requested', 'human_approval_granted', 'human_approval_denied'
--   'agent_dispatched', 'agent_completed', 'agent_failed'
--   'verification_passed', 'verification_failed'
--   'checkpoint_saved', 'checkpoint_loaded'

-- ============================================================
-- RUNS — Top-level grouping of a DAG execution
-- ============================================================
CREATE TABLE IF NOT EXISTS runs (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id          TEXT    NOT NULL UNIQUE,                -- UUID
    dag_id          TEXT    NOT NULL DEFAULT 'default',
    dag_hash        TEXT,                                   -- SHA256 of the DAG JSON
    git_sha         TEXT,                                   -- HEAD at run start
    git_branch      TEXT,                                   -- branch name
    status          TEXT    NOT NULL DEFAULT 'running'
                        CHECK(status IN (
                            'pending','running','succeeded','failed','cancelled'
                        )),
    trigger         TEXT,                                    -- 'manual', 'cron', 'webhook', 'resume'
    started_by      TEXT,                                    -- user or automation name
    total_nodes     INTEGER DEFAULT 0,
    succeeded_nodes INTEGER DEFAULT 0,
    failed_nodes    INTEGER DEFAULT 0,
    total_cost_usd  REAL    DEFAULT 0.0,                    -- accumulated model cost
    total_tokens    INTEGER DEFAULT 0,                       -- accumulated token count
    checkpoint_id   TEXT,                                    -- FK to latest checkpoint
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    completed_at    TEXT,
    duration_seconds INTEGER,                                -- computed at completion

    -- Indexes
    CREATE INDEX idx_runs_status ON runs(status);
    CREATE INDEX idx_runs_dag_id ON runs(dag_id);
);

-- ============================================================
-- RESOURCE POOL — Track concurrency slots
-- ============================================================
CREATE TABLE IF NOT EXISTS resource_pool (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    pool_name       TEXT    NOT NULL UNIQUE,                 -- 'global', 'per-project', 'expensive_model', 'test'
    total_slots     INTEGER NOT NULL,
    used_slots      INTEGER NOT NULL DEFAULT 0,
    last_updated    TEXT NOT NULL DEFAULT (datetime('now')),
    CHECK(used_slots <= total_slots)
);

INSERT OR IGNORE INTO resource_pool (pool_name, total_slots) VALUES
    ('global', 3),
    ('per-project', 1),
    ('expensive_model', 1),
    ('test', 1);

-- ============================================================
-- EVIDENCE GATES — Cached verification results
-- ============================================================
CREATE TABLE IF NOT EXISTS gates (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    gate_name       TEXT    NOT NULL,                       -- e.g. 'lint', 'test', 'coverage', 'intent'
    git_sha         TEXT    NOT NULL,                       -- full SHA
    story_id        TEXT,                                   -- optional FK to story
    passed          INTEGER NOT NULL,                        -- 0 or 1
    evidence_path   TEXT,                                    -- path to evidence artifact
    evidence_hash   TEXT,                                    -- SHA256 of evidence content
    output_summary  TEXT,                                    -- truncated stdout
    duration_ms     INTEGER,                                 -- execution time
    cached          INTEGER DEFAULT 0,                       -- 1 = this is a cache hit (not re-run)
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    expires_at      TEXT NOT NULL,                           -- created_at + 24h
    UNIQUE(gate_name, git_sha)                               -- cache key
);

CREATE INDEX idx_gates_key ON gates(gate_name, git_sha);
CREATE INDEX idx_gates_expires ON gates(expires_at);
```

### Upgrade Path for `harness.db`

```bash
# Migration script — adds new tables to existing harness.db
# Run once before deploying the scheduler upgrade
python3 -c "
import sqlite3, sys

db = sqlite3.connect(sys.argv[1])
db.executescript(open(sys.argv[2]).read())
print('Migration applied successfully')
" "D:/agent-os/harness.db" "path/to/latest-schema.sql"
```

---

## 3. Resource Pool YAML Configuration

### `resource-pool.yaml`

```yaml
# ============================================================
# Resource Pool Configuration — AI Software Factory
# ============================================================
# Controls maximum concurrency across all agent dispatches.
# The scheduler acquires/releases slots before dispatching a task.
# If no slot is available, the task remains in 'pending' state
# until a slot is freed.
#
# Pool hierarchy (checked in order):
#   1. Check 'global' — if full, no task can run
#   2. Check 'expensive_model' — if task.model_id is in expensive_models
#   3. Check 'per-project' — if project-level cap is set
#   4. Check 'test' — if task is a test-only job
# ============================================================

pools:
  # Maximum total concurrent agent dispatches across the entire factory
  global:
    concurrency: 3
    description: >
      Hard limit on simultaneous running tasks.
      Windows 10 + git-bash stability degrades beyond 3 concurrent
      OmniRoute curl invocations. Each dispatch holds one TCP connection
      and one subprocess until the agent returns.

  # Per-project concurrency cap
  per-project:
    concurrency: 1
    description: >
      Maximum simultaneous tasks for a single project (identified by
      dag_id / story_id prefix). Prevents one large project from
      starving others. DEFAULT: 1 until worktree isolation is fully
      verified across all 13 specialist skills.

  # Expensive model reservation (Opus-class reasoning models)
  expensive_model:
    concurrency: 1
    description: >
      Only ONE expensive-model task at a time.
      Expensive models = models whose cost exceeds $0.10/1K tokens
      (Claude Opus, GPT-4 class). Coarser-grained than token budget
      but trivial to enforce at the pool level.
    expensive_model_list:
      - "auto/reasoning:pro"          # Claude Opus via OmniRoute
      - "antigravity/claude-opus-*"
      - "anthropic/claude-opus-*"

  # Test runner pool
  test:
    concurrency: 1
    description: >
      Test execution pool. Even though tests are fast, running
      more than 1 test job concurrently on Windows + git-bash
      causes file-locking conflicts (especially with pytest-cov
      and tempfile-based fixtures).

# ============================================================
# Per-Task Defaults
# ============================================================
defaults:
  max_retries: 2
  task_timeout: 900              # 15 minutes
  evidence_ttl_hours: 24         # evidence cache TTL

  # Retry policy by failure class
  retry_policy:
    TRANSIENT:
      max_retries: 5
      backoff: exponential      # 1s, 2s, 4s, 8s, 16s
    TEST_FAILURE:
      max_retries: 3
      backoff: fixed            # 5s between retries
    ENVIRONMENT:
      max_retries: 2
      backoff: fixed            # 30s between retries
    MODEL_UNAVAILABLE:
      max_retries: 3
      backoff: exponential      # 5s, 10s, 20s
    INTENT_MISMATCH:
      max_retries: 2
      backoff: fixed            # 10s between retries
    FLAKE:
      max_retries: 1
      backoff: none             # immediate retry

    # Non-retryable classes (circuit-breaker fires instead)
    CONTRACT_VIOLATION:
      max_retries: 0
    SPEC_AMBIGUITY:
      max_retries: 0
    SECURITY_FINDING:
      max_retries: 0
    BUDGET_EXCEEDED:
      max_retries: 0
    MERGE_CONFLICT:
      max_retries: 2            # route to integration specialist

# ============================================================
# Circuit Breaker Configuration
# ============================================================
circuit_breaker:
  enabled: true
  threshold: 3                   # Same-class failures in one run
  window_minutes: 60             # Rolling time window
  action: halt_run               # halt entire run when tripped
  reset_after_minutes: 30        # Auto-reset after cooldown
```

### CLI Resource Pool Management

```bash
# Show current pool usage
python3 -c "
import sqlite3, json
db = sqlite3.connect('D:/agent-os/harness.db')
db.row_factory = sqlite3.Row
rows = db.execute('SELECT * FROM resource_pool').fetchall()
print(json.dumps([dict(r) for r in rows], indent=2))
"
```

### Resource Pool Acquire/Release Functions (Python)

```python
"""resource_pool.py — Slot-based concurrency control for the DAG scheduler."""

import sqlite3, json, time
from contextlib import contextmanager

DB_PATH = "D:/agent-os/harness.db"

def get_conn():
    conn = sqlite3.connect(DB_PATH)
    conn.execute("PRAGMA busy_timeout=5000;")
    conn.row_factory = sqlite3.Row
    return conn


def acquire_slot(pool_name: str, timeout: float = 30.0) -> bool:
    """
    Acquire a slot in the named resource pool.
    Blocks until slot available or timeout expires.
    Returns True if slot acquired, False if timeout.
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        conn = get_conn()
        try:
            row = conn.execute(
                "SELECT total_slots, used_slots FROM resource_pool WHERE pool_name=?",
                (pool_name,)
            ).fetchone()
            if row is None:
                return False
            if row["used_slots"] < row["total_slots"]:
                conn.execute(
                    "UPDATE resource_pool SET used_slots = used_slots + 1, last_updated=datetime('now') WHERE pool_name=?",
                    (pool_name,)
                )
                conn.commit()
                return True
        finally:
            conn.close()
        time.sleep(1.0)
    return False


def release_slot(pool_name: str):
    """Release a slot in the named pool."""
    conn = get_conn()
    try:
        conn.execute(
            "UPDATE resource_pool SET used_slots = MAX(0, used_slots - 1), last_updated=datetime('now') WHERE pool_name=?",
            (pool_name,)
        )
        conn.commit()
    finally:
        conn.close()


def resource_pool_acquire(task: sqlite3.Row, conn: sqlite3.Connection) -> bool:
    """Acquire all needed pool slots for a task. Returns True if all acquired."""
    pools_needed = ["global"]

    # Check if this is an expensive model task
    model = task.get("model_id", "")
    expensive_models = [
        "auto/reasoning:pro", "antigravity/claude", "anthropic/claude-opus"
    ]
    if any(m in model for m in expensive_models):
        pools_needed.append("expensive_model")

    pools_needed.append("per-project")
    pools_needed.append("test")

    acquired = []
    for pool in pools_needed:
        if acquire_slot(pool):
            acquired.append(pool)
        else:
            # Release any slots we already acquired
            for p in acquired:
                release_slot(p)
            return False
    return True


def resource_pool_release(task: sqlite3.Row, conn: sqlite3.Connection):
    """Release all pool slots held by a task."""
    release_slot("global")
    release_slot("per-project")
    release_slot("test")
    model = task.get("model_id", "")
    if any(m in model for m in ["auto/reasoning:pro", "antigravity/claude", "anthropic/claude-opus"]):
        release_slot("expensive_model")
```

---

## 4. Windows Defender Exclusion Directories

### The Problem

Windows Defender real-time scanning (`MpEngine`) locks every file during read/write. In the AI Software Factory:

- `dispatch.sh` writes agent output files → Defender scans each write → **200–500ms latency per file**
- `harness.db` SQLite operations → Defender holds file lock → **SQLITE_BUSY errors under concurrent access**
- `work/` directories with thousands of small files → **CPU saturation from scanning**

Without exclusions, even a 3-agent parallel dispatch can trigger 10–30 second delays from AV contention.

### Exclusion Configuration

#### Via PowerShell (Execute Once)

```powershell
# Run as Administrator in PowerShell
# Add-MpPreference appends; -Add overwrites. Use Add for multiple paths.

Write-Host "Adding Windows Defender exclusions for AI Software Factory..."

# Factory control plane
Add-MpPreference -ExclusionPath "D:\hermes-factory" -ErrorAction SilentlyContinue
Write-Host "  ✓ D:\hermes-factory"

# Agent worktrees
Add-MpPreference -ExclusionPath "D:\agent-os\work" -ErrorAction SilentlyContinue
Write-Host "  ✓ D:\agent-os\work"

# Agent artifacts (build output, test results, compiled binaries)
Add-MpPreference -ExclusionPath "D:\agent-os\artifacts" -ErrorAction SilentlyContinue
Write-Host "  ✓ D:\agent-os\artifacts"

# SQLite database (hot path — every state transition writes here)
Add-MpPreference -ExclusionPath "D:\agent-os\harness.db" -ErrorAction SilentlyContinue
Write-Host "  ✓ D:\agent-os\harness.db"

# Events JSONL (append-only audit log)
Add-MpPreference -ExclusionPath "D:\agent-os\events" -ErrorAction SilentlyContinue
Write-Host "  ✓ D:\agent-os\events"

# Node.js / Python virtual environments (scanned once per install)
Add-MpPreference -ExclusionPath "D:\GitRepo\Autonomous-Data-Warehouse\Agent-os\node_modules" -ErrorAction SilentlyContinue
Write-Host "  ✓ Agent-os node_modules"

Add-MpPreference -ExclusionPath "D:\GitRepo\Autonomous-Data-Warehouse\Agent-os\.venv" -ErrorAction SilentlyContinue
Write-Host "  ✓ Agent-os .venv"

Write-Host "`nCurrent exclusion list:"
Get-MpPreference | Select-Object -ExpandProperty ExclusionPath
```

#### Via Registry (For GPO / Unattended Deployment)

```reg
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows Defender\Exclusions\Paths]
"D:\\hermes-factory"=dword:00000000
"D:\\agent-os\\work"=dword:00000000
"D:\\agent-os\\artifacts"=dword:00000000
"D:\\agent-os\\harness.db"=dword:00000000
"D:\\agent-os\\events"=dword:00000000
"D:\\GitRepo\\Autonomous-Data-Warehouse\\Agent-os\\node_modules"=dword:00000000
"D:\\GitRepo\\Autonomous-Data-Warehouse\\Agent-os\\.venv"=dword:00000000
```

#### git-bash Helper (Run as Admin from git-bash)

```bash
#!/usr/bin/env bash
# Run this as Administrator from git-bash to set Defender exclusions
powershell.exe -Command "
Add-MpPreference -ExclusionPath 'D:\hermes-factory';
Add-MpPreference -ExclusionPath 'D:\agent-os\work';
Add-MpPreference -ExclusionPath 'D:\agent-os\artifacts';
Add-MpPreference -ExclusionPath 'D:\agent-os\harness.db';
Add-MpPreference -ExclusionPath 'D:\agent-os\events';
Add-MpPreference -ExclusionPath 'D:\GitRepo\Autonomous-Data-Warehouse\Agent-os\node_modules';
Add-MpPreference -ExclusionPath 'D:\GitRepo\Autonomous-Data-Warehouse\Agent-os\.venv';
Write-Host 'Exclusions added. Verifying...';
Get-MpPreference | Select-Object -ExpandProperty ExclusionPath;
"
```

#### Verification Script

```bash
#!/usr/bin/env bash
# check-defender-exclusions.sh — Verify all required exclusions are set
echo "=== Windows Defender Exclusion Audit ==="
missing=0

check_path() {
    local path="$1"
    local desc="$2"
    if powershell.exe -Command "
        \$paths = Get-MpPreference | Select-Object -ExpandProperty ExclusionPath;
        if (\$paths -contains '$path') { exit 0 } else { exit 1 }
    "; then
        echo "  ✓ $desc ($path)"
    else
        echo "  ✗ MISSING: $desc ($path)"
        missing=$((missing + 1))
    fi
}

check_path "D:\\hermes-factory"              "Factory control plane"
check_path "D:\\agent-os\\work"              "Agent worktrees"
check_path "D:\\agent-os\\artifacts"         "Agent artifacts"
check_path "D:\\agent-os\\harness.db"        "SQLite database"
check_path "D:\\agent-os\\events"            "Event log directory"
check_path "D:\\GitRepo\\Autonomous-Data-Warehouse\\Agent-os\\node_modules" "Node modules"

echo ""
if [ $missing -eq 0 ]; then
    echo "Result: ALL EXCLUSIONS PRESENT"
else
    echo "Result: $missing exclusion(s) MISSING — run the setup script as Administrator"
    exit 1
fi
```

---

## 5. Evidence Caching Design

### Design Overview

**Problem:** Every verification gate (`lint`, `test`, `coverage`, `intent`, `compliance`) re-runs on every dispatch even when the code hasn't changed. On Windows, a `pytest` run takes 30–120s; `compliance.sh` with CVE scanning takes 60–300s. Repeated verification across retries wastes hours.

**Solution:** Cache verification results keyed by `(git_sha, gate_name)` in the `gates` table with a 24-hour TTL. Before running any verification gate, check the cache. If the same `git_sha + gate_name` exists and hasn't expired, skip execution and return the cached result.

### Cache Key Design

```
cache_key = sha256( git_sha + "|" + gate_name )
```

- `git_sha` = full commit SHA (`git rev-parse HEAD`). Any file change produces a new SHA, so the cache automatically invalidates.
- `gate_name` = the exact gate identifier: `lint`, `test`, `coverage`, `intent`, `license_check`, `cve_scan`, `secret_detection`, `provenance`, `sbom`, `structural_eval`.
- **No secondary key needed** — if the code changed, the SHA changed. This is coarser than per-file hashing but trivial to compute and correct.

### Cache Check Logic (in `verify.sh`)

```bash
#!/usr/bin/env bash
# verify.sh — Run verification gates with evidence caching
# Usage: ./verify.sh <db_path> <task_id> <gate_name> [verify_cmd...]

DB="${1:?}"
TASK_ID="${2:?}"
GATE_NAME="${3:?}"
shift 3

# Get git SHA at HEAD
GIT_SHA=$(git rev-parse HEAD 2>/dev/null || echo "unknown")

# Check cache
CACHE_RESULT=$(python3 -c "
import sqlite3, json, sys, hashlib

db = sqlite3.connect('${DB}')
db.row_factory = sqlite3.Row

key_hash = hashlib.sha256(f'${GIT_SHA}|${GATE_NAME}'.encode()).hexdigest()

row = db.execute('''
    SELECT passed, evidence_path, output_summary, created_at, expires_at
    FROM gates
    WHERE gate_name=? AND git_sha=? AND expires_at > datetime('now')
    ORDER BY created_at DESC LIMIT 1
''', ('${GATE_NAME}', '${GIT_SHA}')).fetchone()

if row:
    result = {
        'cached': True,
        'passed': bool(row['passed']),
        'evidence_path': row['evidence_path'],
        'summary': row['output_summary'],
        'created_at': row['created_at'],
        'expires_at': row['expires_at']
    }
else:
    result = {'cached': False}

print(json.dumps(result))
")

CACHED=$(echo "$CACHE_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['cached'])" 2>/dev/null || echo "false")

if [ "$CACHED" = "True" ]; then
    echo "[verify] CACHE HIT for ${GATE_NAME} @ ${GIT_SHA:0:12} — using cached result"
    PASSED=$(echo "$CACHE_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['passed'])")

    # Log cache hit to events
    python3 -c "
import sqlite3, json, uuid
db = sqlite3.connect('${DB}')
db.execute('''
    INSERT INTO events (event_id, run_id, task_id, event_type, payload)
    VALUES (?, ?, ?, 'evidence_cache_hit', ?)
''', (str(uuid.uuid4()), '${TASK_ID%%-*}', '${TASK_ID}',
      json.dumps({'gate':'${GATE_NAME}', 'git_sha':'${GIT_SHA}', 'passed': bool(${PASSED})})))
db.commit()
"

    # Update task with cache hit
    python3 -c "
import sqlite3, hashlib
db = sqlite3.connect('${DB}')
key = hashlib.sha256(f'${GIT_SHA}|${GATE_NAME}'.encode()).hexdigest()
db.execute('UPDATE tasks SET evidence_key=?, cached_hit=1 WHERE task_id=?', (key, '${TASK_ID}'))
db.commit()
"

    if [ "$PASSED" = "True" ]; then
        exit 0
    else
        exit 1
    fi
fi

echo "[verify] CACHE MISS for ${GATE_NAME} @ ${GIT_SHA:0:12} — running verification"

# Run the verification command
set +e
OUTPUT_FILE=$(mktemp /tmp/verify-${GATE_NAME}-XXXXXX.txt)
START_MS=$(date +%s%3N)
(eval "$@") > "$OUTPUT_FILE" 2>&1
VERIFY_EXIT=$?
END_MS=$(date +%s%3N)
DURATION_MS=$((END_MS - START_MS))
set -e

# Compute evidence hash
EVIDENCE_HASH=$(sha256sum "$OUTPUT_FILE" | cut -d' ' -f1)

# Store in gates table
python3 -c "
import sqlite3, json, uuid
db = sqlite3.connect('${DB}')

# Store evidence
db.execute('''
    INSERT OR REPLACE INTO gates
        (gate_name, git_sha, story_id, passed, evidence_path, evidence_hash,
         output_summary, duration_ms, cached, expires_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, datetime('now', '+24 hours'))
''', (
    '${GATE_NAME}',
    '${GIT_SHA}',
    None,
    1 if ${VERIFY_EXIT} == 0 else 0,
    '${OUTPUT_FILE}',
    '${EVIDENCE_HASH}',
    open('${OUTPUT_FILE}').read()[:2000],
    ${DURATION_MS}
))

# Log event
db.execute('''
    INSERT INTO events (event_id, run_id, task_id, event_type, payload)
    VALUES (?, ?, ?, 'evidence_cached', ?)
''', (str(uuid.uuid4()), '${TASK_ID%%-*}', '${TASK_ID}',
      json.dumps({'gate':'${GATE_NAME}', 'git_sha':'${GIT_SHA}',
                  'passed': ${VERIFY_EXIT} == 0, 'duration_ms': ${DURATION_MS},
                  'evidence_hash': '${EVIDENCE_HASH}'})))

# Update task
key = hashlib.sha256(f'${GIT_SHA}|${GATE_NAME}'.encode()).hexdigest()
db.execute('UPDATE tasks SET evidence_key=?, evidence_hash=?, cached_hit=0 WHERE task_id=?',
           (key, '${EVIDENCE_HASH}', '${TASK_ID}'))
db.commit()
"

exit $VERIFY_EXIT
```

### Cache Invalidation Rules

| Event | Cache Action |
|-------|-------------|
| `git commit` | No action — next `verify.sh` sees new `GIT_SHA`, which won't match any existing cache entry |
| `git checkout` branch switch | SHA changes → cache miss → fresh verification |
| `git rebase` | SHA changes → all cached entries invalidated |
| 24h TTL expiry | SQLite `WHERE expires_at > datetime('now')` filters stale rows |
| Manual flush | `DELETE FROM gates WHERE gate_name = 'lint';` |

### Manual Cache Operations

```bash
# Flush cache for a specific gate
python3 -c "
import sqlite3
db = sqlite3.connect('D:/agent-os/harness.db')
db.execute('DELETE FROM gates WHERE gate_name = ?', ('lint',))
db.commit()
print('Cache flushed for gate: lint')
"

# Flush ALL cache
python3 -c "
import sqlite3
db = sqlite3.connect('D:/agent-os/harness.db')
db.execute('DELETE FROM gates')
db.commit()
print('All evidence cache flushed')
"

# Show cache hit rate
python3 -c "
import sqlite3, json
db = sqlite3.connect('D:/agent-os/harness.db')
db.row_factory = sqlite3.Row
rows = db.execute('''
    SELECT gate_name,
           COUNT(*) as total,
           SUM(CASE WHEN cached=1 THEN 1 ELSE 0 END) as hits,
           ROUND(100.0 * SUM(CASE WHEN cached=1 THEN 1 ELSE 0 END) / COUNT(*), 1) as hit_pct
    FROM gates GROUP BY gate_name
''').fetchall()
for r in rows:
    print(f\"  {r['gate_name']:20s}  hits={r['hits']:3d}/{r['total']:3d}  ({r['hit_pct']:5.1f}%)\")
"
```

---

## 6. NSSM Windows Service Wrapper

### Why NSSM

The Non-Sucking Service Manager (NSSM) is the most reliable Windows service wrapper for batch/Python processes. Unlike `srvany` or raw `sc create`:

- **Auto-restart** on crash (configurable delay: 0–86400s)
- **Stdout/stderr capture** to rotating log files
- **Environment variable injection**
- **Working directory control**
- **Dependency ordering** (e.g., wait for `MpsSvc` before starting)
- **Graceful shutdown** via `WM_CLOSE` or `Ctrl+C` before `TerminateProcess`

### Install NSSM

```powershell
# Download nssm-2.24 (latest stable)
# Install to C:\tools\nssm\
mkdir C:\tools\nssm -Force
$nssmUrl = "https://nssm.cc/release/nssm-2.24.zip"
$zipPath = "$env:TEMP\nssm-2.24.zip"
Invoke-WebRequest -Uri $nssmUrl -OutFile $zipPath
Expand-Archive -Path $zipPath -DestinationPath C:\tools\nssm\ -Force
# nssm.exe lives at C:\tools\nssm\nssm-2.24\win64\nssm.exe
# Add to PATH:
[Environment]::SetEnvironmentVariable(
    "PATH",
    [Environment]::GetEnvironmentVariable("PATH", "Machine") + ";C:\tools\nssm\nssm-2.24\win64",
    "Machine"
)
```

### Service Configuration — `hermes-factory`

```powershell
# ============================================================
# hermes-factory NSSM Service — Install Script
# Run as Administrator in PowerShell
# ============================================================

$nssm = "C:\tools\nssm\nssm-2.24\win64\nssm.exe"
$serviceName = "HermesFactory"
$displayName = "Hermes AI Software Factory Scheduler"
$description = "DAG task scheduler for the AI Software Factory — " +
               "manages multi-level DAG dispatch, resource pools, " +
               "evidence caching, and circuit breaker. Runs continuously " +
               "as the factory control plane."

# Stop and remove existing service if present
& $nssm stop $serviceName 2>$null
& $nssm remove $serviceName confirm 2>$null
Start-Sleep -Seconds 2

# --- Install ---
& $nssm install $serviceName

# --- Application ---
& $nssm set $serviceName Application "C:\Program Files\Git\bin\bash.exe"
& $nssm set $serviceName AppParameters "D:\GitRepo\Autonomous-Data-Warehouse\Agent-os\scripts\factory-daemon.sh"

# --- Working Directory ---
& $nssm set $serviceName AppDirectory "D:\GitRepo\Autonomous-Data-Warehouse\Agent-os"

# --- Environment ---
& $nssm set $serviceName AppEnvironmentExtra `
    "PATH=C:\Program Files\Git\bin;C:\Program Files\Git\usr\bin;C:\Users\vanga\.local\bin;C:\tools\nssm\nssm-2.24\win64;$env:PATH" `
    "HOME=C:\Users\vanga" `
    "HERMES_PROFILE=sdlc-orchestrator" `
    "HERMES_FACTORY_DIR=D:\hermes-factory" `
    "AGENT_OS_DIR=D:\agent-os" `
    "PYTHONUNBUFFERED=1" `
    "NSSM_LOG_DIR=D:\hermes-factory\logs"

# --- Logging (stdout + stderr to rotating files) ---
& $nssm set $serviceName AppStdout "D:\hermes-factory\logs\factory-stdout.log"
& $nssm set $serviceName AppStderr "D:\hermes-factory\logs\factory-stderr.log"
& $nssm set $serviceName AppRotateFiles 1
& $nssm set $serviceName AppRotateOnline 1
& $nssm set $serviceName AppRotateSeconds 86400   # Rotate daily
& $nssm set $serviceName AppRotateBytes 10485760  # 10MB max per file
& $nssm set $serviceName AppRotateBytesHigh 0     # Delete oldest after limit

# --- Restart Behavior ---
& $nssm set $serviceName AppRestartDelay 5000      # 5 seconds before restart
& $nssm set $serviceName AppThrottle 0             # No throttle on restart
& $nssm set $serviceName AppExit Default Exit      # Treat all exits as restartable

# --- Process Management ---
& $nssm set $serviceName AppStopMethodSkip 0
& $nssm set $serviceName AppStopMethodConsole 3000   # Send Ctrl+C, wait 3s
& $nssm set $serviceName AppStopMethodWindow 5000    # Send WM_CLOSE, wait 5s
& $nssm set $serviceName AppStopMethodThreads 8000   # Wait for threads, 8s
& $nssm set $serviceName AppStopMethodTerminate 10000 # Force kill after 10s

# --- Dependencies ---
# Wait for network (LanmanWorkstation) and SQLite availability
& $nssm set $serviceName Dependencies "LanmanWorkstation/MpsSvc"

# --- Display ---
& $nssm set $serviceName DisplayName $displayName
& $nssm set $serviceName Description $description
& $nssm set $serviceName Start SERVICE_AUTO_START

# --- Object Name (run as LOCAL SYSTEM by default) ---
# If running as a specific user:
# & $nssm set $serviceName ObjectName ".\vanga" "password"

Write-Host "Service '$serviceName' installed successfully."
Write-Host "Starting service..."
& $nssm start $serviceName
Start-Sleep -Seconds 3
& $nssm status $serviceName
```

### Factory Daemon Script

```bash
#!/usr/bin/env bash
# factory-daemon.sh — Main loop for the Hermes Factory NSSM service
# Runs continuously, polling for new DAG runs in the task queue.
set -euo pipefail

FACTORY_DIR="${HERMES_FACTORY_DIR:-D:/hermes-factory}"
AGENT_OS_DIR="${AGENT_OS_DIR:-D:/agent-os}"
DB="${AGENT_OS_DIR}/harness.db"
SCRIPTS_DIR="${AGENT_OS_DIR}/scripts"
LOG_DIR="${FACTORY_DIR}/logs"
POLL_INTERVAL=10  # seconds

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log "Hermes Factory Daemon starting..."
log "  Factory dir: ${FACTORY_DIR}"
log "  Agent OS:    ${AGENT_OS_DIR}"
log "  DB:          ${DB}"
log "  Poll:        ${POLL_INTERVAL}s"

# Ensure DB has required tables
if [ ! -f "$DB" ]; then
    log "ERROR: harness.db not found at ${DB}"
    exit 1
fi

# Trap for graceful shutdown
cleanup() {
    log "Shutting down gracefully..."
    # Write a shutdown event
    python3 -c "
import sqlite3, uuid
db = sqlite3.connect('${DB}')
db.execute(\"INSERT INTO events (event_id, run_id, event_type, payload) VALUES (?, 'daemon', 'daemon_shutdown', '{}')\",
           (str(uuid.uuid4()),))
db.commit()
" 2>/dev/null || true
    log "Goodbye."
    exit 0
}
trap cleanup SIGTERM SIGINT

# Check for pending DAGs on startup
python3 -c "
import sqlite3
db = sqlite3.connect('${DB}')
count = db.execute(\"SELECT COUNT(*) FROM runs WHERE status='pending'\").fetchone()[0]
print(f'  Pending runs: {count}')
"

log "Entering main loop..."

while true; do
    # Check for new pending runs
    PENDING_RUNS=$(python3 -c "
import sqlite3, json
db = sqlite3.connect('${DB}')
db.row_factory = sqlite3.Row
runs = db.execute(\"SELECT run_id, dag_id FROM runs WHERE status='pending' ORDER BY created_at ASC LIMIT 1\").fetchall()
print(json.dumps([dict(r) for r in runs]))
")

    if [ "$PENDING_RUNS" != "[]" ] && [ "$PENDING_RUNS" != "" ]; then
        RUN_ID=$(echo "$PENDING_RUNS" | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['run_id'])")
        DAG_ID=$(echo "$PENDING_RUNS" | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['dag_id'])")
        log "Found pending run: ${RUN_ID} (dag: ${DAG_ID})"

        # Mark run as running
        python3 -c "
import sqlite3
db = sqlite3.connect('${DB}')
db.execute(\"UPDATE runs SET status='running' WHERE run_id=?\", ('${RUN_ID}',))
db.commit()
"

        # Execute the DAG scheduler
        log "Launching schedule.sh for run ${RUN_ID}..."
        cd "${SCRIPTS_DIR}"
        if bash "${SCRIPTS_DIR}/schedule.sh" "$DB" "${FACTORY_DIR}/dags/${DAG_ID}.json"; then
            python3 -c "
import sqlite3
db = sqlite3.connect('${DB}')
db.execute(\"UPDATE runs SET status='succeeded', completed_at=datetime('now') WHERE run_id=?\", ('${RUN_ID}',))
db.commit()
"
            log "Run ${RUN_ID} completed successfully."
        else
            python3 -c "
import sqlite3
db = sqlite3.connect('${DB}')
db.execute(\"UPDATE runs SET status='failed', completed_at=datetime('now') WHERE run_id=?\", ('${RUN_ID}',))
db.commit()
"
            log "Run ${RUN_ID} FAILED. Check logs for details."
        fi

        cd "$FACTORY_DIR"
    fi

    sleep "$POLL_INTERVAL"
done
```

### Service Management Commands

```powershell
# --- STATUS ---
& "C:\tools\nssm\nssm-2.24\win64\nssm.exe" status HermesFactory

# --- START ---
& "C:\tools\nssm\nssm-2.24\win64\nssm.exe" start HermesFactory

# --- STOP ---
& "C:\tools\nssm\nssm-2.24\win64\nssm.exe" stop HermesFactory

# --- RESTART ---
& "C:\tools\nssm\nssm-2.24\win64\nssm.exe" restart HermesFactory

# --- EDIT CONFIG (GUI) ---
& "C:\tools\nssm\nssm-2.24\win64\nssm.exe" edit HermesFactory

# --- VIEW LOG ---
Get-Content "D:\hermes-factory\logs\factory-stdout.log" -Tail 50

# --- VIEW ERROR LOG ---
Get-Content "D:\hermes-factory\logs\factory-stderr.log" -Tail 50

# --- UNINSTALL ---
& "C:\tools\nssm\nssm-2.24\win64\nssm.exe" stop HermesFactory
& "C:\tools\nssm\nssm-2.24\win64\nssm.exe" remove HermesFactory confirm
```

### Log Rotation Config (NSSM inline)

The NSSM config above already sets rotation:

```powershell
# Rotation settings (set during install):
#   AppRotateFiles 1         — Enable rotation
#   AppRotateOnline 1        — Rotate without restarting service
#   AppRotateSeconds 86400   — Rotate every 24 hours
#   AppRotateBytes 10485760  — Rotate when file reaches 10 MB
#   AppRotateBytesHigh 0     — Delete oldest when count exceeds (0 = no limit)
```

Rotated logs are stored in the same directory with timestamps:

```
D:\hermes-factory\logs\
  ├── factory-stdout.log              # Current stdout
  ├── factory-stdout.20260728T120000.log  # Rotated stdout
  ├── factory-stdout.20260729T120000.log
  ├── factory-stderr.log              # Current stderr
  └── factory-stderr.20260728T120000.log  # Rotated stderr
```

### Service Recovery Policy (Windows-level)

NSSM handles process-level restart, but Windows Service Control Manager can also auto-restart:

```powershell
# Set SCM recovery options as backup
sc.exe failure HermesFactory reset=86400 actions=restart/5000/restart/10000/restart/30000
```

---

## Implementation Roadmap

### Phase 1 — Schema & Database (Day 1)
1. Run SQLite DDL to add `tasks`, `events`, `runs`, `resource_pool`, `gates` tables to `harness.db`
2. Add migration script to `scripts/migrate-v2.sh`
3. Verify with `python3 -c "import sqlite3; ..."` that all tables exist and constraints work

### Phase 2 — Resource Pool (Day 1–2)
1. Create `scripts/resource_pool.py` with acquire/release functions
2. Create `config/resource-pool.yaml` (from §3 above)
3. Write unit test: acquire 4 slots on 3-capacity pool → 4th returns False
4. Wire into `schedule.sh`

### Phase 3 — DAG Scheduler (Day 2–3)
1. Rewrite `_dag_scheduler.py` with the full state machine
2. Update `schedule.sh` to invoke the Python scheduler
3. Write transition tests for all 13 states
4. Test: 7-node DAG from M3 (3 parallel "impl" nodes) completes all states correctly

### Phase 4 — Evidence Caching (Day 3)
1. Update `verify.sh` with cache-check logic from §5
2. Write cache hit/miss integration test
3. Test: run same gate twice on same SHA → second is cache hit

### Phase 5 — Defender Exclusions (Day 3)
1. Run `scripts/set-defender-exclusions.ps1` as Administrator
2. Run `scripts/check-defender-exclusions.sh` to verify
3. Measure: `time pytest` before/after exclusions

### Phase 6 — NSSM Service (Day 4)
1. Install NSSM to `C:\tools\nssm\`
2. Run `scripts/install-factory-service.ps1` as Administrator
3. Verify: `nssm status HermesFactory` → `SERVICE_RUNNING`
4. Test: kill factory daemon process → NSSM restarts within 5s
5. Test: reboot machine → service auto-starts

### Phase 7 — Integration Test (Day 4–5)
1. Full end-to-end: DAG file → schedule.sh → resource pool → verify.sh with caching → completion
2. Measure wall-clock time reduction from caching
3. Document any Windows-specific edge cases

---

## Appendix A: Event Type Reference

| Event Type | Producer | Description |
|---|---|---|
| `run_started` | scheduler | New DAG run initiated |
| `run_completed` | scheduler | All terminal nodes resolved |
| `run_failed` | scheduler | Run terminated with errors |
| `dag_loaded` | scheduler | DAG JSON parsed into tasks table |
| `dag_complete` | scheduler | Last node reached terminal state |
| `state_transition` | scheduler | Task moved from old_state to new_state |
| `evidence_cached` | verify.sh | Gate result stored in gates table |
| `evidence_cache_hit` | verify.sh | Gate result served from cache |
| `evidence_cache_miss` | verify.sh | Gate result not in cache, re-running |
| `resource_acquired` | scheduler | Pool slot acquired for task |
| `resource_released` | scheduler | Pool slot released by task |
| `resource_timeout` | scheduler | Pool slot acquisition timed out |
| `circuit_breaker_tripped` | circuit-breaker.sh | ≥3 same-class failures, run halted |
| `human_approval_requested` | scheduler | T3 task waiting for human gate |
| `human_approval_granted` | approve.sh | Human approved T3 task |
| `human_approval_denied` | approve.sh | Human rejected T3 task |
| `agent_dispatched` | scheduler | Task sent to OmniRoute / agent |
| `agent_completed` | scheduler | Agent returned with exit 0 |
| `agent_failed` | scheduler | Agent returned with exit ≠ 0 |
| `verification_passed` | scheduler/verify.sh | Gate verification passed |
| `verification_failed` | scheduler/verify.sh | Gate verification failed |
| `checkpoint_saved` | checkpoint.sh | Run state serialized to checkpoint JSON |
| `checkpoint_loaded` | resume.sh | Run state restored from checkpoint |
| `daemon_started` | factory-daemon.sh | NSSM service started |
| `daemon_shutdown` | factory-daemon.sh | NSSM service stopping |

## Appendix B: File Layout After Upgrade

```
D:/agent-os/
├── harness.db                     # SQLite database (tasks, events, runs, pools, gates)
├── .git/
├── events/                        # JSONL files (redundant audit trail)
├── work/                          # Git worktrees per task
├── artifacts/                     # Build outputs and evidence artifacts
├── config/
│   └── resource-pool.yaml         # Resource pool configuration
├── scripts/
│   ├── schedule.sh                # [REWRITE] Multi-level DAG scheduler entry point
│   ├── _dag_scheduler.py          # [NEW] Python scheduler with full state machine
│   ├── _resource_pool.py          # [NEW] Slot-based concurrency control
│   ├── _evidence_cache.py         # [NEW] Cache check/store helpers
│   ├── dispatch.sh                # [DEPRECATED] Replaced by schedule.sh
│   ├── dag.sh                     # [UPDATE] DAG construction → SQLite loading
│   ├── verify.sh                  # [UPDATE] Evidence caching wrapper
│   ├── feedback-loop.sh           # [UPDATE] Write failure_class to events table
│   ├── circuit-breaker.sh         # [UPDATE] Read tasks table grouped by class
│   ├── checkpoint.sh              # [UPDATE] Include run_id + full task snapshot
│   ├── resume.sh                  # [UPDATE] Restore tasks table from checkpoint
│   ├── migrate-v2.sh              # [NEW] DB migration for new tables
│   ├── set-defender-exclusions.ps1     # [NEW] PowerShell exclusion setup
│   ├── check-defender-exclusions.sh    # [NEW] Exclusion verification
│   ├── install-factory-service.ps1     # [NEW] NSSM service installer
│   └── factory-daemon.sh          # [NEW] NSSM service main loop
├── logs/                          # NSSM log rotation target
│   ├── factory-stdout.log
│   └── factory-stderr.log
└── dags/                          # DAG JSON files for scheduled runs
    └── default.json

D:/hermes-factory/
├── config/
│   └── resource-pool.yaml         # (copy or symlink)
└── logs/                          # NSSM logs (primary)
    ├── factory-stdout.log
    ├── factory-stderr.log
    └── factory-stdout.20260728T120000.log  # rotated
```
