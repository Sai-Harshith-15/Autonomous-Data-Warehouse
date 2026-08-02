#!/usr/bin/env python3
"""
_dag_scheduler.py — Multi-level DAG Scheduler with 13-state machine.
Reads a plan/run, manages the task lifecycle, enforces resource pools,
and persists state to SQLite (harness.db).

Usage:
  python _dag_scheduler.py --plan <plan.yaml> --run-id <R-2026-...> [--dry-run]
  python _dag_scheduler.py --status <run-id>
  python _dag_scheduler.py --retry <run-id> --task-id <T-...>
"""

import json, sys, os, time, hashlib, subprocess, threading, shlex
from datetime import datetime, timezone, timedelta
from pathlib import Path

# Module-level import for TaskResult (used in dispatch_task exception handler)
try:
    from runtime.worker_base import TaskResult
except ImportError:
    TaskResult = None  # type: ignore

# ─── Worker Runtime ────────────────────────────────────────────────────────
# Lazy-import workers so the scheduler works without runtime/ deps
# when running verification-only tasks.
_RUNTIME_LOADED = False
_WORKERS = []

def _load_workers():
    global _RUNTIME_LOADED, _WORKERS
    if _RUNTIME_LOADED:
        return
    try:
        from runtime.worker_verification import VerificationWorker
        from runtime.worker_omniroute import OmniRouteCodingWorker
        _WORKERS = [OmniRouteCodingWorker(), VerificationWorker()]
    except ImportError:
        # Fall back — inline TaskResult as a simple dict
        _WORKERS = []
    _RUNTIME_LOADED = True

# ─── Config ──────────────────────────────────────────────────────────────
REPO_ROOT = Path(__file__).resolve().parent.parent
FACTORY_HOME = Path(os.environ.get("FACTORY_HOME", REPO_ROOT / ".factory"))
DB_PATH = os.environ.get("HARNESS_DB", str(FACTORY_HOME / "state" / "harness.db"))
POOL_CONFIG = os.environ.get("POOL_CONFIG", str(REPO_ROOT / "scripts" / "config" / "resource-pool.yaml"))
RUNS_DIR = Path(os.environ.get("RUNS_DIR", FACTORY_HOME / "runs"))
EVENTS_DIR = RUNS_DIR  # events live inside runs dir
LOCK_TIMEOUT = 30  # seconds

# ─── States ───────────────────────────────────────────────────────────────
STATE_PENDING           = "pending"
STATE_READY             = "ready"
STATE_CLAIMED           = "claimed"
STATE_RUNNING          = "running"
STATE_SUCCEEDED        = "succeeded"
STATE_FAILED           = "failed"
STATE_BLOCKED          = "blocked"
STATE_RETRYING         = "retrying"
STATE_CANCELLED        = "cancelled"
STATE_AWAITING_APPROVAL = "awaiting_approval"

TERMINAL_STATES = {STATE_SUCCEEDED, STATE_FAILED, STATE_CANCELLED}
ACTIVE_STATES   = {STATE_CLAIMED, STATE_RUNNING, STATE_RETRYING}
RECOVERABLE     = {STATE_FAILED, STATE_RETRYING}

# ─── DB Helpers ───────────────────────────────────────────────────────────

def db_conn():
    conn = sqlite3.connect(DB_PATH, timeout=LOCK_TIMEOUT)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=30000")
    return conn

import sqlite3

def get_run(run_id):
    with db_conn() as conn:
        row = conn.execute("SELECT * FROM runs WHERE run_id=?", (run_id,)).fetchone()
        return dict(row) if row else None

def update_run_status(run_id, status, elapsed_ms=None):
    with db_conn() as conn:
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%fZ")
        if status == "running":
            conn.execute("UPDATE runs SET status=?, started_at=? WHERE run_id=?", (status, now, run_id))
        elif status in ("succeeded", "failed", "cancelled"):
            conn.execute("UPDATE runs SET status=?, finished_at=?, elapsed_ms=? WHERE run_id=?",
                        (status, now, elapsed_ms, run_id))
        else:
            conn.execute("UPDATE runs SET status=? WHERE run_id=?", (status, run_id))
        conn.commit()

def get_tasks(run_id):
    with db_conn() as conn:
        rows = conn.execute("SELECT * FROM tasks WHERE run_id=? ORDER BY task_id", (run_id,)).fetchall()
        return [dict(r) for r in rows]

def get_task(run_id, task_id):
    with db_conn() as conn:
        row = conn.execute("SELECT * FROM tasks WHERE run_id=? AND task_id=?", (run_id, task_id)).fetchone()
        return dict(row) if row else None

def update_task_status(run_id, task_id, status, **kw):
    with db_conn() as conn:
        sets = ["status=?"]
        vals = [status]
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%fZ")
        if status == STATE_CLAIMED:
            sets.append("started_at=?")
            vals.append(now)
        elif status == STATE_RETRYING:
            sets.append("started_at=?")
            vals.append(now)
            retry_count = kw.get("retry_count", 1)
            # Exponential backoff: 2^retry_count * 30 seconds
            backoff_seconds = (2 ** min(retry_count, 5)) * 30
            from datetime import timedelta
            retry_after = (datetime.now(timezone.utc) + timedelta(seconds=backoff_seconds)).strftime("%Y-%m-%dT%H:%M:%fZ")
            sets.append("retry_after=?")
            vals.append(retry_after)
        elif status in (STATE_SUCCEEDED, STATE_FAILED, STATE_CANCELLED):
            sets.append("finished_at=?")
            vals.append(now)
            if "elapsed_ms" in kw:
                sets.append("elapsed_ms=?")
                vals.append(kw["elapsed_ms"])
        if "failure_class" in kw:
            sets.append("failure_class=?")
            vals.append(kw["failure_class"])
        if "result_summary" in kw:
            sets.append("result_summary=?")
            vals.append(kw["result_summary"])
        if "commit_sha" in kw:
            sets.append("commit_sha=?")
            vals.append(kw["commit_sha"])
        if "retry_count" in kw:
            sets.append("retry_count=?")
            vals.append(kw["retry_count"])
        sets.append("metadata=?")
        vals.append(json.dumps(kw.get("metadata", {})))
        vals += [run_id, task_id]
        conn.execute(f"UPDATE tasks SET {', '.join(sets)} WHERE run_id=? AND task_id=?", vals)
        conn.commit()

def insert_event(run_id, event_type, task_id=None, agent=None, tool=None,
                 file_changed=None, gate=None, outcome=None, summary="", **kw):
    """Thread-safe event insertion."""
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%fZ")
    with db_conn() as conn:
        conn.execute("""INSERT INTO events (schema_version, time, run_id, task_id, event_type,
                        agent, tool, file_changed, gate, outcome, summary, metadata)
                        VALUES (2, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    (now, run_id, task_id, event_type, agent, tool,
                     file_changed, gate, outcome, summary, json.dumps(kw.get("metadata", {}))))
        conn.commit()
    # Also write to JSONL for dashboard streaming
    runs_dir = RUNS_DIR / str(run_id)
    runs_dir.mkdir(parents=True, exist_ok=True)
    ev = {"schema_version": 2, "time": now, "run_id": run_id, "task_id": task_id,
          "event_type": event_type, "agent": agent, "tool": tool,
          "file_changed": file_changed, "gate": gate, "elapsed_ms": kw.get("elapsed_ms"),
          "outcome": outcome, "summary": summary, "metadata": kw.get("metadata", {})}
    with open(runs_dir / "events.jsonl", "a") as f:
        f.write(json.dumps(ev, separators=(",", ":")) + "\n")

def cache_lookup(git_sha, gate_name):
    """Check evidence cache: return (outcome, exit_code) or None."""
    cache_key = hashlib.sha256(f"{git_sha}|{gate_name}".encode()).hexdigest()
    with db_conn() as conn:
        row = conn.execute("""SELECT outcome, exit_code FROM gates
                              WHERE cache_key=? AND invalidated=0
                              AND expires_at > datetime('now')""", (cache_key,)).fetchone()
        if row:
            return dict(row)
        return None

def cache_store(run_id, task_id, gate_name, git_sha, outcome, exit_code, command, stdout_path, elapsed_ms):
    """Store gate result in evidence cache (24h TTL)."""
    cache_key = hashlib.sha256(f"{git_sha}|{gate_name}".encode()).hexdigest()
    with db_conn() as conn:
        conn.execute("""INSERT OR REPLACE INTO gates
                        (run_id, task_id, gate_name, git_sha, cache_key, outcome,
                         exit_code, command, stdout_path, elapsed_ms, expires_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                                datetime('now', '+24 hours'))""",
                    (run_id, task_id, gate_name, git_sha, cache_key, outcome,
                     exit_code, command, stdout_path, elapsed_ms))
        conn.commit()

def acquire_slot(pool_name, task_id):
    """Acquire a resource pool slot atomically with BEGIN IMMEDIATE."""
    with db_conn() as conn:
        conn.execute("BEGIN IMMEDIATE")
        pool = conn.execute(
            "SELECT pool_name, max_slots FROM resource_pool WHERE pool_name=?",
            (pool_name,)
        ).fetchone()
        if not pool:
            conn.execute("COMMIT")
            return True
        
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

def release_slot(pool_name, task_id):
    """Release a resource pool slot."""
    with db_conn() as conn:
        conn.execute("DELETE FROM pool_slots WHERE pool_name=? AND task_id=?", (pool_name, task_id))
        conn.commit()

def release_all_slots(task_id):
    """Release all slots held by a task."""
    with db_conn() as conn:
        conn.execute("DELETE FROM pool_slots WHERE task_id=?", (task_id,))
        conn.commit()

# ─── DAG Logic ────────────────────────────────────────────────────────────

def compute_readiness(tasks):
    """Compute which tasks are READY based on dependency status."""
    dep_map = {}
    for t in tasks:
        deps = json.loads(t.get("depends_on", "[]") or "[]")
        dep_map[t["task_id"]] = deps

    ready = []
    for t in tasks:
        sid = t["task_id"]
        if t["status"] == STATE_PENDING:
            deps = dep_map.get(sid, [])
            if not deps:
                ready.append(sid)
                continue
            # Check all deps succeeded
            dep_states = {}
            for d in dep_map[sid]:
                for t2 in tasks:
                    if t2["task_id"] == d:
                        dep_states[d] = t2["status"]
                        break
            blocked = False
            for d, st in dep_states.items():
                if st in (STATE_FAILED, STATE_CANCELLED):
                    blocked = True
                    # Mark this task as blocked
                    update_task_status(t["run_id"], sid, STATE_BLOCKED,
                                       summary=f"Depends on {d} which is {st}")
                    break
            if not blocked and all(st == STATE_SUCCEEDED for st in dep_states.values()):
                ready.append(sid)
        elif t["status"] == STATE_RETRYING:
            # Check if retry_after has elapsed
            retry_after = t.get("retry_after")
            if retry_after:
                try:
                    from datetime import datetime, timezone
                    ra = datetime.fromisoformat(retry_after)
                    if ra <= datetime.now(timezone.utc):
                        update_task_status(t["run_id"], sid, STATE_PENDING, summary="Retry backoff elapsed")
                        # Don't add to ready yet — needs one more pass
                except (ValueError, TypeError):
                    pass
    return ready

def count_tasks(tasks, status):
    return sum(1 for t in tasks if t["status"] == status)

def is_run_complete(tasks):
    """All tasks reached terminal state."""
    for t in tasks:
        if t["status"] not in TERMINAL_STATES | {STATE_BLOCKED, STATE_AWAITING_APPROVAL}:
            return False
    return True

def get_status_counts(tasks):
    counts = {}
    for t in tasks:
        st = t["status"]
        counts[st] = counts.get(st, 0) + 1
    return counts

def _exec_cmd(cmd, **kwargs):
    """Execute command safely — no shell=True."""
    if isinstance(cmd, str):
        cmd_parts = shlex.split(cmd)
    else:
        cmd_parts = list(cmd)
    return subprocess.run(cmd_parts, shell=False, **kwargs)


# ─── Dispatch ─────────────────────────────────────────────────────────────

def dispatch_task(task_id, run_id):
    """Execute a task via the appropriate worker (coding agent or verification)."""
    _load_workers()
    task = get_task(run_id, task_id)
    if not task:
        return

    # Mark running
    update_task_status(run_id, task_id, STATE_RUNNING)
    insert_event(run_id, "task_started", task_id=task_id, summary=f"Started: {task['goal']}")

    # Create task log directory
    task_dir = Path(RUNS_DIR) / str(run_id) / "tasks" / task_id
    task_dir.mkdir(parents=True, exist_ok=True)

    # Route to first matching worker
    result = None
    for worker in _WORKERS:
        if worker.can_handle(task):
            insert_event(run_id, "task_dispatched", task_id=task_id,
                         agent=worker.worker_label,
                         summary=f"Worker: {worker.worker_label}")
            start_ts = time.time()
            try:
                result = worker.execute(task, run_id, task_dir)
            except Exception as e:
                elapsed = int((time.time() - start_ts) * 1000)
                result = TaskResult(
                    success=False,
                    summary=f"Worker exception: {e}",
                    evidence={"exit_code": -3, "stdout": "", "stderr": str(e)},
                    failure_class="ENVIRONMENT",
                )
            break

    # Handle result
    total_elapsed = int((time.time() - start_ts) * 1000) if result else 0

    if result and result.success:
        update_task_status(run_id, task_id, STATE_SUCCEEDED, elapsed_ms=total_elapsed,
                           result_summary=result.summary,
                           metadata={"evidence": result.evidence})
        insert_event(run_id, "task_completed", task_id=task_id, outcome="success",
                     elapsed_ms=total_elapsed, summary=result.summary)
    else:
        failure_class = result.failure_class if result else "NO_WORKER"
        retry_count = task.get("retry_count", 0) + 1
        max_retries = task.get("max_retries", 2)
        if retry_count <= max_retries and failure_class in ("TEST_FAILURE", "TRANSIENT", "ENVIRONMENT", "OMNIROUTE_ERROR", "EMPTY_RESPONSE", "API_ERROR"):
            update_task_status(run_id, task_id, STATE_RETRYING, retry_count=retry_count,
                               failure_class=failure_class, elapsed_ms=total_elapsed)
            insert_event(run_id, "task_failed", task_id=task_id, outcome="retrying",
                         elapsed_ms=total_elapsed,
                         summary=f"Retry {retry_count}/{max_retries}: {failure_class}")
        else:
            update_task_status(run_id, task_id, STATE_FAILED, retry_count=retry_count,
                               failure_class=failure_class, elapsed_ms=total_elapsed)
            insert_event(run_id, "task_failed", task_id=task_id, outcome="failed",
                         elapsed_ms=total_elapsed,
                         summary=f"Failed: {failure_class} — {result.summary if result else 'No worker available'}")

    release_all_slots(task_id)


def ensure_schema():
    """Ensure schema is up to date. Run at startup."""
    with db_conn() as conn:
        # Add retry_after column if missing
        try:
            conn.execute("ALTER TABLE tasks ADD COLUMN retry_after TEXT")
        except sqlite3.OperationalError:
            pass  # already exists


# ─── Main Scheduler Loop ──────────────────────────────────────────────────

def scheduler_loop(run_id, dry_run=False):
    """Main loop: find ready tasks, claim resources, dispatch, repeat."""
    ensure_schema()
    run = get_run(run_id)
    if not run:
        print(f"[scheduler] Run {run_id} not found", file=sys.stderr)
        return 1

    update_run_status(run_id, "running")
    insert_event(run_id, "run_started", summary="Pipeline started")
    run_start = time.time()

    tasks = get_tasks(run_id)
    update_run_status(run_id, "running")

    def update_progress():
        tasks = get_tasks(run_id)
        counts = get_status_counts(tasks)
        done = counts.get(STATE_SUCCEEDED, 0)
        failed = counts.get(STATE_FAILED, 0)
        total = len(tasks)
        with db_conn() as conn:
            conn.execute("UPDATE runs SET done_tasks=?, failed_tasks=?, total_tasks=? WHERE run_id=?",
                        (done, failed, total, run_id))
            conn.commit()
        return counts

    # Main loop
    max_iterations = 100  # safety limit
    iteration = 0
    stale_claims = {}  # task_id → timestamp
    while iteration < max_iterations:
        iteration += 1
        tasks = get_tasks(run_id)
        if is_run_complete(tasks):
            break

        # Recover stale claims (claimed > 60s without progress)
        now = time.time()
        for t in tasks:
            if t["status"] == STATE_CLAIMED:
                sid = t["task_id"]
                if sid not in stale_claims:
                    stale_claims[sid] = now
                elif now - stale_claims[sid] > 60:
                    # Stale claim — reset to pending so it can be re-attempted
                    update_task_status(run_id, sid, STATE_PENDING,
                                       summary="Recovered from stale claim")
                    release_all_slots(sid)
                    insert_event(run_id, "task_failed", task_id=sid,
                                 outcome="recovered", summary="Stale claim timeout → reset")
                    del stale_claims[sid]

        # Find ready tasks
        ready_ids = compute_readiness(tasks)

        if not ready_ids:
            # Check if anything is still running or no progress possible
            active = [t for t in tasks if t["status"] in ACTIVE_STATES]
            blocked = [t for t in tasks if t["status"] == STATE_BLOCKED]
            pending = [t for t in tasks if t["status"] == STATE_PENDING]
            if not active and pending:
                # All remaining pending are blocked by failed deps
                for t in pending:
                    update_task_status(run_id, t["task_id"], STATE_BLOCKED)
                break
            if not active:
                break  # nothing to do
            # Wait for active tasks
            time.sleep(2)
            continue

        # Try to claim ready tasks within resource limits
        for task_id in ready_ids:
            task = get_task(run_id, task_id)
            if not task:
                continue

            # Check resource pools
            if not acquire_slot("global", task_id):
                continue  # global concurrency limit hit

            # Mark as claimed, then dispatch
            update_task_status(run_id, task_id, STATE_CLAIMED)
            insert_event(run_id, "task_claimed", task_id=task_id, summary="Slot acquired")

            if dry_run:
                print(f"[dry-run] Would dispatch: {task_id}: {task['goal']}")
                update_task_status(run_id, task_id, STATE_SUCCEEDED, elapsed_ms=0)
                release_all_slots(task_id)
            else:
                # Dispatch in a thread so we can parallelize
                t = threading.Thread(target=dispatch_task, args=(task_id, run_id), daemon=True)
                t.start()

        update_progress()
        time.sleep(1)

    # Wait for all running/retrying tasks to finish
    wait_start = time.time()
    while time.time() - wait_start < 600:  # 10 min max wait
        tasks = get_tasks(run_id)
        active = [t for t in tasks if t["status"] in ACTIVE_STATES]
        if not active:
            break
        time.sleep(2)

    # Final status
    tasks = get_tasks(run_id)
    counts = update_progress()
    elapsed = int((time.time() - run_start) * 1000)

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

    update_run_status(run_id, run_status, elapsed_ms=elapsed)
    insert_event(run_id, "run_completed", outcome=run_status, elapsed_ms=elapsed,
                 summary=f"Total: {total}, Succeeded: {succeeded}, Failed: {failed}, Blocked: {blocked}")

    print(f"[scheduler] Run {run_id} completed: {succeeded}/{total} passed, {failed} failed, {blocked} blocked in {elapsed}ms")
    return 0 if failed == 0 and blocked == 0 else 1

# ─── CLI ──────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="DAG Scheduler for AI Software Factory")
    parser.add_argument("--run-id", help="Existing run ID to process")
    parser.add_argument("--plan", help="Plan YAML file to create run from (future)")
    parser.add_argument("--dry-run", action="store_true", help="Dry run (no actual dispatch)")
    parser.add_argument("--status", help="Show run status")
    parser.add_argument("--status-all", action="store_true", help="Show all recent runs")

    args = parser.parse_args()

    if args.status:
        run = get_run(args.status)
        if not run:
            print(f"Run {args.status} not found")
            sys.exit(1)
        tasks = get_tasks(args.status)
        counts = get_status_counts(tasks)
        print(f"Run: {run['run_id']}")
        print(f"Status: {run['status']}")
        print(f"Project: {run['project']}")
        print(f"Tasks: {counts}")
        print(f"Elapsed: {run.get('elapsed_ms', 'N/A')}ms")
        sys.exit(0)

    if args.status_all:
        with db_conn() as conn:
            rows = conn.execute("SELECT run_id, status, project, created_at, elapsed_ms, done_tasks, total_tasks FROM runs ORDER BY created_at DESC LIMIT 20").fetchall()
        print(f"{'Run ID':<25} {'Status':<15} {'Project':<15} {'Done':<8} {'Elapsed':<10}")
        print("-" * 80)
        for r in rows:
            print(f"{r['run_id']:<25} {r['status']:<15} {r['project']:<15} {r['done_tasks']}/{r['total_tasks']:<6} {r['elapsed_ms'] or 'N/A':<10}")
        sys.exit(0)

    if not args.run_id:
        print("Usage: python _dag_scheduler.py --run-id <R-...> [--dry-run]")
        print("       python _dag_scheduler.py --status <run-id>")
        print("       python _dag_scheduler.py --status-all")
        sys.exit(1)

    sys.exit(scheduler_loop(args.run_id, dry_run=args.dry_run))
