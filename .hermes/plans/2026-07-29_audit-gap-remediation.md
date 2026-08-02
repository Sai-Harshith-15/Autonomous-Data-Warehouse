# AI Software Factory — Audit Gap Remediation Plan

> **Goal:** Fix all critical and high-severity gaps identified in `audit_gaps.md` against the live codebase, making the factory reliable for unattended SDLC pipelines.
>
> **Audit source:** `audit_gaps.md` (1,462 lines, 9 sections)
> **Code verified:** `Agent-os/scripts/_dag_scheduler.py`, `dashboard.py`, `db/schema.sql`
> **Verification date:** 2026-07-29
>
> **Architecture:** Phase-gated remediation — each phase has exit criteria. P0 (safety) before P1 (integrity) before P2 (quality). P0 fixes can be applied in parallel; P1 and P2 stack on top.

---

## Phase 0 — Critical Safety (P0)

Fixes that prevent data loss, infinite hangs, or command injection.

### Task P0-1: Fix retry deadlock (C2)

**Files:**
- Modify: `Agent-os/scripts/_dag_scheduler.py:326-337`, `:193`

**Problem:** Task set to `STATE_RETRYING` (line 329) never re-enters the ready loop because `compute_readiness()` only checks `STATE_PENDING` (line 193). The run hangs waiting for active tasks (line 440-447).

**Fix:**
1. Add `retry_at` timestamp to the task row in the DB (but SQLite has it — the `started_at` field stores when retry was initiated; need a new column or repurpose).
   - **Decision:** Add `retry_after` TEXT column (ISO timestamp) to tasks table, default NULL.
2. In `compute_readiness()`, add a check: if a task is `retrying` AND `retry_after <= now()`, promote to `pending`.
3. When setting retry, compute backoff: `retry_after = now() + (2^retry_count * 30) seconds`.
4. Add backoff to `insert_event` call so dashboard shows when retry fires.

**Add column:**
```sql
ALTER TABLE tasks ADD COLUMN retry_after TEXT;
```

**Modified readiness logic (pseudocode):**
```python
# Before: skip non-pending
if t["status"] == STATE_PENDING:
    # existing deps check
elif t["status"] == STATE_RETRYING:
    retry_after = t.get("retry_after")
    if retry_after and parse_iso(retry_after) <= datetime.now(timezone.utc):
        update_task_status(run_id, sid, STATE_PENDING, summary="Retry backoff elapsed")
        # fall through to be picked up next iteration
```

**Verification:**
```bash
cd /d/GitRepo/Autonomous-Data-Warehouse/Agent-os
python -m py_compile scripts/_dag_scheduler.py
# Create a test with a transiently failing task and verify it retries
```

---

### Task P0-2: Replace shell=True with structured argv (C3)

**Files:**
- Modify: `Agent-os/scripts/_dag_scheduler.py:287`

**Problem:** `subprocess.run(cmd, shell=True, ...)` passes task verification commands from YAML directly to the shell. Any model-generated or external content can inject arbitrary commands.

**Fix:**
1. Change `subprocess.run` call to accept both structured (list) and string commands.
2. For string commands, split via `shlex.split()` — not shell eval.
3. Always use `shell=False`.
4. Log the command as an argument array, not a flattened string.

**Code change:**
```python
# Instead of:
result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=...)

# Use:
if isinstance(cmd, str):
    import shlex
    cmd_parts = shlex.split(cmd)
else:
    cmd_parts = cmd
result = subprocess.run(cmd_parts, shell=False, capture_output=True, text=True, timeout=...)
```

**Verification:**
```bash
cd /d/GitRepo/Autonomous-Data-Warehouse/Agent-os
python -m py_compile scripts/_dag_scheduler.py
# Run a test task with known commands
```

---

### Task P0-3: Eliminate hard-coded D:/ paths (C4)

**Files:**
- Modify: `Agent-os/scripts/_dag_scheduler.py:19-22`
- Modify: `Agent-os/scripts/dashboard.py:25-27`

**Problem:** 6 hard-coded `D:/agent-os/...` and `D:/hermes-factory/...` paths prevent running from a clean checkout, WSL, or alternate drive.

**Fix:** Adopt `FACTORY_HOME` env-var pattern:

```python
REPO_ROOT = Path(__file__).resolve().parents[1]
FACTORY_HOME = Path(os.environ.get("FACTORY_HOME", REPO_ROOT / ".factory"))
DB_PATH = os.environ.get("HARNESS_DB", str(FACTORY_HOME / "state" / "harness.db"))
POOL_CONFIG = os.environ.get("POOL_CONFIG", str(REPO_ROOT / "scripts" / "config" / "resource-pool.yaml"))
RUNS_DIR = Path(os.environ.get("RUNS_DIR", FACTORY_HOME / "runs"))
EVENTS_DIR = Path(os.environ.get("EVENTS_DIR", FACTORY_HOME / "events"))
```

**Also:** Create `scripts/config/resource-pool.yaml` (moved from hard-coded D:/ path):

```yaml
pools:
  global:
    max_slots: 3
  per_project:
    max_slots: 1
  expensive:
    max_slots: 1
  test:
    max_slots: 1
retry:
  max_retries: 2
  backoff_seconds: 30
```

**Verification:**
```bash
cd /d/GitRepo/Autonomous-Data-Warehouse/Agent-os
grep -rn "D:/agent-os\|D:/hermes-factory" scripts/
# Should return 0 matches
```

---

## Phase 1 — Functional Integrity (P1)

Fixes that prevent resource leaks, incorrect results, and dashboard exposure.

### Task P1-1: Fix resource pool race condition (C1)

**Files:**
- Modify: `Agent-os/scripts/_dag_scheduler.py:156-167`

**Problem:** `acquire_slot()` checks `used_slots` via SELECT, then calls INSERT INTO pool_slots in a separate transaction. Between SELECT and INSERT, another thread can grab the last slot (TOCTOU race). The SQLite triggers correctly maintain `used_slots`, but the check happens BEFORE the trigger fires.

**Fix:** Use `BEGIN IMMEDIATE` transaction and count actual pool_slots:

```python
def acquire_slot(pool_name, task_id):
    """Acquire a resource pool slot atomically. Returns True if acquired."""
    with db_conn() as conn:
        conn.execute("BEGIN IMMEDIATE")
        pool = conn.execute(
            "SELECT pool_name, max_slots FROM resource_pool WHERE pool_name=?",
            (pool_name,)
        ).fetchone()
        if not pool:
            conn.execute("COMMIT")
            return True  # pool doesn't exist → unlimited
        
        current = conn.execute(
            "SELECT COUNT(*) as cnt FROM pool_slots WHERE pool_name=?",
            (pool_name,)
        ).fetchone()
        
        if current["cnt"] >= pool["max_slots"]:
            conn.execute("COMMIT")
            return False
        
        conn.execute(
            "INSERT INTO pool_slots (pool_name, task_id) VALUES (?, ?)",
            (pool_name, task_id)
        )
        conn.execute("COMMIT")
        return True
```

**Verification:** Write a test that starts 5 tasks but concurrency limit is 2 — verify only 2 run simultaneously.

---

### Task P1-2: Add coding-agent execution contract (H1)

**Files:**
- Modify: `Agent-os/scripts/_dag_scheduler.py:235-339`
- Create: `Agent-os/scripts/worker_base.py`

**Problem:** `dispatch_task()` only runs verification commands. Tasks with empty `verification` auto-succeed. The scheduler doesn't launch coding agents, create worktrees, or collect diffs.

**Fix:** Introduce a worker abstraction:

```python
# worker_base.py
class TaskWorker:
    """Base class for task workers."""
    def run(self, task, run_dir) -> dict:
        raise NotImplementedError

class VerificationWorker(TaskWorker):
    """Runs verification commands (existing behavior)."""
    ...

class CodingAgentWorker(TaskWorker):
    """Launches a coding agent (opencode, codex, etc.)."""
    ...
```

In `dispatch_task()`:
1. Check `task.get("worker_type", "verification")` 
2. Route to appropriate worker
3. A task with empty `verification` AND no `worker_type` → mark as `awaiting_approval` instead of auto-succeeding
4. Collect: exit code, stdout/stderr paths, git diff (if applicable), changed files list

**Verification:** A task with empty verification_cmds and no worker_type must NOT auto-succeed.

---

### Task P1-3: Fix dashboard CORS & binding (H2)

**Files:**
- Modify: `Agent-os/scripts/dashboard.py:28`

**Problem:** `allow_origins=["*"]` and `allow_methods=["*"]` make the dashboard accessible from any origin. No authentication.

**Fix:**
```python
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://127.0.0.1:8199", "http://localhost:8199"],
    allow_credentials=False,
    allow_methods=["GET"],
    allow_headers=["Content-Type"],
)
```

Also add a note in the file header: **"Bind to 127.0.0.1 only — do not expose to 0.0.0.0 without authentication."**

**Verification:**
```python
# Check the CORS config is non-wildcard
grep "allow_origins" Agent-os/scripts/dashboard.py
```

---

### Task P1-4: Fix run completion status ignoring blocked tasks (H3)

**Files:**
- Modify: `Agent-os/scripts/_dag_scheduler.py:454-465`

**Problem:** Line 459 sets `run_status = STATE_SUCCEEDED if failed == 0 else STATE_FAILED`. A run with 0 failed but 3 blocked is reported as "succeeded". Line 465's return code correctly returns 1 if blocked > 0, but the stored status is wrong.

**Fix:**
```python
total = len(tasks)
succeeded = counts.get(STATE_SUCCEEDED, 0)
failed = counts.get(STATE_FAILED, 0)
blocked = counts.get(STATE_BLOCKED, 0)
cancelled = counts.get(STATE_CANCELLED, 0)
awaiting = counts.get(STATE_AWAITING_APPROVAL, 0)

if cancelled > 0:
    run_status = STATE_CANCELLED
elif failed > 0:
    run_status = STATE_FAILED
elif blocked > 0:
    run_status = STATE_BLOCKED
elif awaiting > 0:
    run_status = STATE_AWAITING_APPROVAL
else:
    run_status = STATE_SUCCEEDED
```

---

### Task P1-5: Make stale claim recovery persistent (H5)

**Files:**
- Modify: `Agent-os/scripts/_dag_scheduler.py:375-393`, schema

**Problem:** `stale_claims` is a plain Python dict. Scheduler restart loses tracking. Only `claimed` tasks (not `running`) checked.

**Fix:**
1. Add `claimed_at` TEXT and `heartbeat_at` TEXT columns to tasks table
2. Set `claimed_at` when marking `claimed` (line 425)
3. Add a `recover_stale_tasks()` function called at scheduler startup:
   ```sql
   UPDATE tasks SET status = 'pending'
   WHERE status IN ('claimed', 'running')
     AND (heartbeat_at IS NULL OR heartbeat_at < datetime('now', '-120 seconds'))
   ```
4. Release all pool slots for recovered tasks
5. Insert recovery events

**Verification:**
```bash
# Start a task, kill scheduler, restart — task should recover to pending
```

---

## Phase 2 — Quality & Hardening (P2)

### Task P2-1: Worktree isolation (M1)

<!-- Future: one worktree per task using `git worktree add` -->
Implementation deferred until coding-agent worker is active (P1-2), since verification-only tasks don't need write isolation.

### Task P2-2: Broaden gate cache key (M2)

**Files:**
- Modify: `Agent-os/scripts/_dag_scheduler.py:145`

Add `environment_digest` (hash of Python version, OS, major tool versions) and `lockfile_digest` to cache key:

```python
def environment_digest():
    import platform, sys
    parts = [
        platform.system(), platform.release(), sys.version,
        "pytest=" + __import__("pytest").__version__,
    ]
    return hashlib.sha256("|".join(parts).encode()).hexdigest()[:16]

cache_key = hashlib.sha256(f"{git_sha}|{gate_name}|{environment_digest()}".encode()).hexdigest()
```

### Task P2-3: Log redaction layer (M3)

**Files:**
- Create: `Agent-os/scripts/redact.py`

Implement a redaction function called before writing stdout/stderr/events:

```python
SECRET_PATTERNS = [
    (r'(?:OPENAI_API_KEY|ANTHROPIC_API_KEY|GITHUB_TOKEN|AWS_SECRET_ACCESS_KEY)\s*=\s*\S+', r'\1=***REDACTED***'),
    (r'Bearer\s+[A-Za-z0-9\-._~+/]+=*', 'Bearer ***REDACTED***'),
    (r'ghp_[A-Za-z0-9]{36}', '***REDACTED***'),
    (r'sk-[A-Za-z0-9]{32,}', '***REDACTED***'),
    (r'-----BEGIN (?:RSA |EC )?PRIVATE KEY-----.*?-----END (?:RSA |EC )?PRIVATE KEY-----', '***REDACTED PRIVATE KEY***'),
]

def redact(text: str, registered_values: list[str] = None) -> str:
    """Redact secrets from text."""
    for pattern, replacement in SECRET_PATTERNS:
        text = re.sub(pattern, replacement, text, flags=re.DOTALL)
    if registered_values:
        for val in registered_values:
            if val and len(val) > 4:
                text = text.replace(val, '***REDACTED***')
    return text
```

### Task P2-4: Agent registry (M4)

**Files:**
- Create: `Agent-os/agents/registry.yaml`

```yaml
agents:
  sdlc-backend-engineer:
    skill_path: .agents/skills/sdlc-backend-engineer/SKILL.md
    worker_type: coding_agent
    allowed_task_kinds: [backend_implementation, backend_repair]
  sdlc-frontend-engineer:
    skill_path: .agents/skills/sdlc-frontend-engineer/SKILL.md
    worker_type: coding_agent
    allowed_task_kinds: [frontend_implementation]
  sdlc-qa-engineer:
    skill_path: .agents/skills/sdlc-qa-engineer/SKILL.md
    worker_type: coding_agent
    allowed_task_kinds: [qa_test_creation, qa_test_fix]
  sdlc-security-reviewer:
    skill_path: .agents/skills/sdlc-security-reviewer/SKILL.md
    worker_type: review_agent
    allowed_task_kinds: [security_review]
  sdlc-software-architect:
    skill_path: .agents/skills/sdlc-software-architect/SKILL.md
    worker_type: review_agent
    allowed_task_kinds: [architecture_review, adr_writing]
```

### Task P2-5: Cleanup backup files (M5)

```bash
cd /d/GitRepo/Autonomous-Data-Warehouse
git rm Agent-os/projects/fastapi-health/tests/test_health.py.bak
```

Add to `.gitignore`:
```
*.bak
*.orig
*~
```

### Task P2-6: Reorganize factory/examples (M6)

Move `projects/` → `examples/` for clarity:
```bash
mkdir -p Agent-os/examples
git mv Agent-os/projects/* Agent-os/examples/
```

---

## Execution Order

```
Phase 0 (parallel groups):
├── P0-1 (retry fix) ─────────────────┐
├── P0-2 (shell=False) ───────────────┤ parallel batch
├── P0-3a: scheduler D:/ paths ───────┤
├── P0-3b: dashboard D:/ paths ───────┘
└── P0-3c: resource-pool.yaml config

Phase 1 (stacked on P0):
├── P1-1 (pool race)
├── P1-2 (worker contract)
├── P1-3 (CORS fix)
├── P1-4 (blocked status)
└── P1-5 (persistent recovery)

Phase 2 (independent):
├── P2-2 (cache key)
├── P2-3 (redaction)
├── P2-4 (agent registry)
├── P2-5 (cleanup)
└── P2-6 (reorg)
```

---

## Validation

After P0 + P1 are complete, run:

1. **Syntax check:** `python -m compileall Agent-os/scripts/`
2. **Dashboard smoke:** `uvicorn dashboard:app --host 127.0.0.1 --port 8199` (verify health endpoint)
3. **Scheduler smoke:** Create a 2-level DAG, run it, verify all states + events
4. **Retry test:** Induce TEST_FAILURE on first attempt, verify retry fires
5. **Concurrency test:** 5 tasks, pool max=2, verify only 2 run at once
6. **No D:/ paths:** `grep -rn 'D:/' scripts/` → 0 matches

---

## Open Risks

- **P1-2 (worker contract) is the most complex change.** It touches the core dispatch loop. Consider splitting into two sub-P1 tasks: (a) add worker abstraction without changing behavior, (b) add coding-agent worker.
- **P2-1 (worktree isolation) depends on P1-2.** Cannot implement worktree isolation without knowing how workers use the workspace. Deferred to post-P1.
- **Dashboard auth** is explicitly deferred — local-only binding is sufficient for v1.
