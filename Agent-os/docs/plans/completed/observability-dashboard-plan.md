# AI Software Factory — Production-Readiness Plan: Observability & Dashboard Layer

> **Date:** 2026-07-28
> **Context:** Factory has 47 events in `public/factory-events.json`, 24 verified shell scripts, no live dashboard, no real-time visibility into running pipelines.
> **Target:** FastAPI SSE dashboard runnable as Windows service via NSSM, streaming logs, health monitoring, structured event schema.

---

## 1. Structured JSONL Event Schema

Every event in the factory MUST conform to this schema. This is the **single source of truth** — all dashboards, replays, and health metrics derive from it.

```json
{
  "schema_version": 2,
  "time": "2026-07-28T14:30:00.123Z",
  "run_id": "R-2026-07-28-042",
  "task_id": "T-2026-0042",
  "event_type": "task_started",
  "agent": "opencode-go/deepseek-v4-pro",
  "tool": "git-commit",
  "file_changed": "backend/src/auth/login.py",
  "gate": "implementation",
  "elapsed_ms": null,
  "outcome": null,
  "summary": "Started OAuth login endpoint implementation",
  "metadata": {}
}
```

### Allowed `event_type` values

| event_type | When emitted | `elapsed_ms` | `outcome` |
|---|---|---|---|
| `run_started` | New pipeline run begins | null | null |
| `run_completed` | Pipeline run ends | total run ms | `success` / `failed` |
| `run_failed` | Pipeline run aborted | total run ms | failure class |
| `task_started` | Task dispatched to agent | null | null |
| `task_completed` | Task succeeded | task duration ms | `success` |
| `task_failed` | Task failed | task duration ms | failure class |
| `task_blocked` | Task blocked on dependency/gate | ms blocked so far | `blocked` |
| `gate_passed` | Phase gate verified | gate duration ms | `pass` |
| `gate_failed` | Phase gate rejected | gate duration ms | `fail` |
| `gate_escalated` | Gate escalated to human | gate duration ms | `escalated` |
| `tool_call` | Tool invoked by agent | tool duration ms | `success` / `error` |
| `file_written` | File created/changed by agent | null | null |
| `checkpoint` | Run checkpoint saved | ms since run start | checkpoint SHA |
| `heartbeat` | Periodic liveness ping | ms since last heartbeat | null |

### Writer contract

Every factory script appends to the **run-specific** JSONL file:

```bash
# D:/agent-os/scripts/trace.sh (upgraded to v2)
TRACE_DIR="/d/agent-os/runs/${run_id}"
mkdir -p "$TRACE_DIR"

cat >> "${TRACE_DIR}/events.jsonl" <<JSONL
{"schema_version":2,"time":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","run_id":"${run_id}","task_id":"${task_id:-null}","event_type":"${event_type}","agent":"${agent:-null}","tool":"${tool:-null}","file_changed":"${file_changed:-null}","gate":"${gate:-null}","elapsed_ms":${elapsed_ms:-null},"outcome":"${outcome:-null}","summary":"${summary}","metadata":${metadata:-{}}}
JSONL
```

Migration path: wrap `dashboard-bridge.sh` to also emit v2 events to `runs/<run-id>/events.jsonl`. The old `factory-events.json` remains as backward-compatible aggregate.

---

## 2. Minimal FastAPI Dashboard Server

Single-file `dashboard.py` that serves:
- `GET /api/events` — SSE stream of live events
- `GET /api/runs` — list of all known runs with summary stats
- `GET /api/health` — health metrics JSON
- `GET /` — static HTML dashboard page

### `dashboard.py`

```python
"""dashboard.py — Single-file FastAPI dashboard server for AI Software Factory.

Start:  uvicorn dashboard:app --host 0.0.0.0 --port 8080
Install as Windows service:  nssm install factory-dashboard "C:\Users\vanga\AppData\Local\Programs\Python\Python311\python.exe" "-m uvicorn dashboard:app --host 0.0.0.0 --port 8080"
"""

import asyncio
import json
import os
import time
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse, StreamingResponse

# --- Configuration ---
EVENTS_DIR = Path("/d/agent-os/runs")
HEALTH_LOG_DIR = Path("/d/agent-os/logs")
TASKS_DIR = Path("/d/agent-os/tasks")
PUBLIC_JSON = Path("/d/agent-os/public/factory-events.json")
POLL_INTERVAL = 0.5  # seconds between file checks

app = FastAPI(title="AI Software Factory Dashboard")

# ---------------------------------------------------------------------------
# In-memory state (rebuilt from JSONL on startup + live updates)
# ---------------------------------------------------------------------------

class FactoryState:
    def __init__(self):
        self.runs: dict[str, dict] = {}
        self.events: list[dict] = []
        self.last_event_time: str | None = None
        self._replay_done = False

    def replay_events(self):
        """Rebuild state from all runs/<run-id>/events.jsonl files."""
        if self._replay_done:
            return
        if not EVENTS_DIR.exists():
            return
        for run_dir in sorted(EVENTS_DIR.iterdir()):
            if not run_dir.is_dir():
                continue
            events_file = run_dir / "events.jsonl"
            if not events_file.exists():
                continue
            run_id = run_dir.name
            self.runs.setdefault(run_id, {
                "run_id": run_id,
                "project": "unknown",
                "state": "unknown",
                "started_at": None,
                "elapsed_s": 0,
                "tasks_done": 0,
                "tasks_total": 0,
                "tasks_running": [],
                "tasks_completed": [],
                "tasks_blocked": [],
                "events_count": 0,
            })
            with open(events_file) as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    ev = json.loads(line)
                    self.events.append(ev)
                    self._apply_event(run_id, ev)
        self._replay_done = True

    def _apply_event(self, run_id: str, ev: dict):
        run = self.runs[run_id]
        run["events_count"] += 1
        et = ev.get("event_type", "")
        ts = ev.get("time", "")
        if run["started_at"] is None or ts < run["started_at"]:
            run["started_at"] = ts

        if et == "run_started":
            run["state"] = "running"
            run["project"] = ev.get("summary", "unknown").replace("Started run for ", "")
        elif et == "run_completed":
            run["state"] = "completed"
        elif et == "run_failed":
            run["state"] = "failed"
        elif et == "task_started":
            run["tasks_running"].append({
                "task_id": ev.get("task_id"),
                "agent": ev.get("agent"),
                "elapsed_s": 0,
                "started_at": ts,
            })
        elif et == "task_completed":
            tid = ev.get("task_id")
            run["tasks_running"] = [t for t in run["tasks_running"] if t["task_id"] != tid]
            run["tasks_completed"].append(tid)
            run["tasks_done"] += 1
        elif et == "task_failed":
            tid = ev.get("task_id")
            run["tasks_running"] = [t for t in run["tasks_running"] if t["task_id"] != tid]
            run["tasks_completed"].append(f"{tid}(FAILED)")
            run["tasks_done"] += 1
        elif et == "task_blocked":
            run["tasks_blocked"].append(ev.get("task_id"))
            run["state"] = "blocked"

        if run["started_at"] and ts:
            try:
                start = datetime.fromisoformat(run["started_at"].replace("Z", "+00:00"))
                now = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                run["elapsed_s"] = int((now - start).total_seconds())
            except (ValueError, TypeError):
                pass

# ---------------------------------------------------------------------------
# SSE Event Source
# ---------------------------------------------------------------------------

state = FactoryState()

async def event_generator(request: Request):
    """Yield SSE events: existing state replay + live tail."""
    state.replay_events()

    # 1. Replay existing events as SSE
    for ev in state.events[-500:]:  # last 500 events
        if await request.is_disconnected():
            return
        yield f"data: {json.dumps(ev)}\n\n"
        await asyncio.sleep(0.01)

    # 2. Live tail — poll runs/<latest-run>/events.jsonl
    last_size = {}
    while True:
        if await request.is_disconnected():
            break
        if not EVENTS_DIR.exists():
            await asyncio.sleep(POLL_INTERVAL)
            continue
        # Watch all run dirs
        for run_dir in sorted(EVENTS_DIR.iterdir()):
            if not run_dir.is_dir():
                continue
            events_file = run_dir / "events.jsonl"
            if not events_file.exists():
                continue
            fpath = str(events_file)
            try:
                st = events_file.stat()
                current_size = st.st_size
                last = last_size.get(fpath, 0)
                if current_size > last:
                    with open(events_file) as f:
                        f.seek(last)
                        for line in f:
                            line = line.strip()
                            if line:
                                ev = json.loads(line)
                                state.events.append(ev)
                                state._apply_event(run_dir.name, ev)
                                yield f"data: {json.dumps(ev)}\n\n"
                    last_size[fpath] = current_size
            except (OSError, json.JSONDecodeError):
                pass
        await asyncio.sleep(POLL_INTERVAL)

# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@app.get("/api/events")
async def api_events(request: Request):
    return StreamingResponse(
        event_generator(request),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )

@app.get("/api/runs")
async def api_runs():
    state.replay_events()
    return JSONResponse(sorted(
        state.runs.values(),
        key=lambda r: r.get("started_at", ""),
        reverse=True,
    ))

@app.get("/api/health")
async def api_health():
    state.replay_events()
    running_count = sum(1 for r in state.runs.values() if r["state"] == "running")
    failed_count = sum(1 for r in state.runs.values() if r["state"] == "failed")
    queue_depth = running_count  # active runs in queue
    token_usage_total = 0
    cost_usd_total = 0.0
    task_durations = []
    for ev in state.events:
        if ev.get("elapsed_ms") is not None:
            task_durations.append(ev["elapsed_ms"])
    avg_duration = (
        round(sum(task_durations) / len(task_durations))
        if task_durations
        else 0
    )
    return JSONResponse({
        "status": "healthy",
        "queue_depth": queue_depth,
        "running_count": running_count,
        "failed_count": failed_count,
        "avg_task_duration_ms": avg_duration,
        "token_usage_total": token_usage_total,
        "cost_usd_total": cost_usd_total,
        "total_runs": len(state.runs),
        "total_events": len(state.events),
        "timestamp": datetime.now(timezone.utc).isoformat(),
    })

@app.get("/", response_class=HTMLResponse)
async def index():
    return HTMLResponse(HTML_DASHBOARD)

# ---------------------------------------------------------------------------
# Inline HTML Dashboard (single-page, no dependencies)
# ---------------------------------------------------------------------------

HTML_DASHBOARD = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>AI Software Factory — Dashboard</title>
<style>
  :root {
    --bg: #0d1117; --surface: #161b22; --border: #30363d;
    --text: #c9d1d9; --text-dim: #8b949e; --accent: #58a6ff;
    --green: #3fb950; --red: #f85149; --yellow: #d29922; --blue: #58a6ff;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
         background: var(--bg); color: var(--text); padding: 24px; }
  h1 { font-size: 1.5rem; margin-bottom: 4px; }
  .subtitle { color: var(--text-dim); font-size: 0.85rem; margin-bottom: 20px; }
  .stats-bar { display: flex; gap: 16px; margin-bottom: 20px; flex-wrap: wrap; }
  .stat-card { background: var(--surface); border: 1px solid var(--border); border-radius: 6px;
               padding: 12px 20px; flex: 1; min-width: 120px; }
  .stat-card .label { font-size: 0.75rem; color: var(--text-dim); text-transform: uppercase; }
  .stat-card .value { font-size: 1.5rem; font-weight: 600; margin-top: 4px; }
  .stat-card .value.green { color: var(--green); }
  .stat-card .value.red { color: var(--red); }
  .stat-card .value.yellow { color: var(--yellow); }
  .stat-card .value.blue { color: var(--blue); }
  table { width: 100%; border-collapse: collapse; background: var(--surface);
          border: 1px solid var(--border); border-radius: 6px; overflow: hidden; }
  th { text-align: left; padding: 10px 12px; font-size: 0.75rem; color: var(--text-dim);
       text-transform: uppercase; border-bottom: 1px solid var(--border); background: #0d1117; }
  td { padding: 10px 12px; border-top: 1px solid var(--border); font-size: 0.85rem; vertical-align: top; }
  .badge { display: inline-block; padding: 2px 8px; border-radius: 12px; font-size: 0.75rem;
           font-weight: 500; }
  .badge.running { background: #1a3a1a; color: var(--green); }
  .badge.completed { background: #1a2a1a; color: #8bcea8; }
  .badge.failed { background: #3a1a1a; color: var(--red); }
  .badge.blocked { background: #3a2a00; color: var(--yellow); }
  .agent-tag { display: inline-block; background: #1f2a3a; color: var(--blue); padding: 1px 6px;
               border-radius: 4px; font-size: 0.75rem; margin: 1px; }
  .btn { display: inline-block; padding: 4px 12px; border-radius: 4px; font-size: 0.75rem;
         text-decoration: none; color: var(--text); background: #21262d; border: 1px solid var(--border);
         cursor: pointer; }
  .btn:hover { background: #30363d; }
  .btn.danger { color: var(--red); }
  .event-log { margin-top: 20px; background: var(--surface); border: 1px solid var(--border);
               border-radius: 6px; max-height: 300px; overflow-y: auto; padding: 12px; }
  .event-log .entry { padding: 4px 0; border-bottom: 1px solid #1a1a1a; font-size: 0.8rem;
                      font-family: 'Consolas', 'Courier New', monospace; }
  .event-log .entry .ts { color: var(--text-dim); margin-right: 8px; }
  .event-log .entry .ev-type { color: var(--accent); margin-right: 8px; }
  .event-log .entry .summary { color: var(--text); }
</style>
</head>
<body>
<h1>🏭 AI Software Factory</h1>
<p class="subtitle">Real-time pipeline dashboard — <span id="event-count">0</span> events processed</p>

<div class="stats-bar" id="stats-bar">
  <div class="stat-card"><div class="label">Runs</div><div class="value blue" id="stat-runs">—</div></div>
  <div class="stat-card"><div class="label">Running</div><div class="value yellow" id="stat-running">—</div></div>
  <div class="stat-card"><div class="label">Completed</div><div class="value green" id="stat-completed">—</div></div>
  <div class="stat-card"><div class="label">Failed</div><div class="value red" id="stat-failed">—</div></div>
  <div class="stat-card"><div class="label">Queue Depth</div><div class="value" id="stat-queue">—</div></div>
  <div class="stat-card"><div class="label">Avg Task</div><div class="value" id="stat-avg-ms">—</div></div>
</div>

<table id="runs-table">
  <thead>
    <tr>
      <th>Run ID</th><th>Project</th><th>State</th><th>Elapsed</th>
      <th>Tasks</th><th>Running</th><th>Completed</th><th>Blocked</th><th>Actions</th>
    </tr>
  </thead>
  <tbody id="runs-tbody"></tbody>
</table>

<div class="event-log" id="event-log">
  <div style="color:var(--text-dim);font-size:0.8rem;padding:8px;">Waiting for events…</div>
</div>

<script>
const EVENT_LIMIT = 200;
let events = [];
let stats = { runs: 0, running: 0, completed: 0, failed: 0, queue: 0, avgMs: 0 };

function fmtElapsed(s) {
  if (!s && s !== 0) return '—';
  const m = Math.floor(s / 60), sec = s % 60;
  return m > 0 ? `${m}m ${sec}s` : `${sec}s`;
}

function fmtTime(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  return d.toLocaleTimeString();
}

function renderStats() {
  document.getElementById('stat-runs').textContent = stats.runs;
  document.getElementById('stat-running').textContent = stats.running;
  document.getElementById('stat-completed').textContent = stats.completed;
  document.getElementById('stat-failed').textContent = stats.failed;
  document.getElementById('stat-queue').textContent = stats.queue;
  document.getElementById('stat-avg-ms').textContent = stats.avgMs ? stats.avgMs + 'ms' : '—';
}

function renderTable(runs) {
  const tbody = document.getElementById('runs-tbody');
  tbody.innerHTML = runs.map(r => {
    const stateBadge = `<span class="badge ${r.state}">${r.state}</span>`;
    const runningAgents = (r.tasks_running || []).map(t =>
      `<span class="agent-tag">${t.agent || '?'} (${fmtElapsed(t.elapsed_s)})</span>`
    ).join('');
    return `<tr>
      <td><strong>${r.run_id}</strong></td>
      <td>${r.project}</td>
      <td>${stateBadge}</td>
      <td>${fmtElapsed(r.elapsed_s)}</td>
      <td>${r.tasks_done}/${r.tasks_total || r.tasks_completed.length}</td>
      <td>${runningAgents || '<span style="color:var(--text-dim)">—</span>'}</td>
      <td>${(r.tasks_completed || []).join(', ') || '<span style="color:var(--text-dim)">—</span>'}</td>
      <td>${(r.tasks_blocked || []).join(', ') || '<span style="color:var(--text-dim)">—</span>'}</td>
      <td>
        <a class="btn" href="#" onclick="viewRun('${r.run_id}');return false;">View</a>
        <a class="btn danger" href="#" onclick="cancelRun('${r.run_id}');return false;">Cancel</a>
      </td>
    </tr>`;
  }).join('');
}

function renderEventLog() {
  const log = document.getElementById('event-log');
  const recent = events.slice(-50);
  log.innerHTML = recent.map(e => {
    const ts = e.time ? fmtTime(e.time) : '';
    const type = e.event_type || '?';
    const summary = e.summary || '';
    return `<div class="entry">
      <span class="ts">${ts}</span>
      <span class="ev-type">${type}</span>
      <span class="summary">${summary}</span>
    </div>`;
  }).join('');
}

function processEvent(ev) {
  events.push(ev);
  if (events.length > EVENT_LIMIT) events.shift();
  document.getElementById('event-count').textContent = events.length;
}

async function fetchRuns() {
  try {
    const res = await fetch('/api/runs');
    const runs = await res.json();
    const running = runs.filter(r => r.state === 'running').length;
    const completed = runs.filter(r => r.state === 'completed' || r.state === 'success').length;
    const failed = runs.filter(r => r.state === 'failed').length;
    stats = { runs: runs.length, running, completed, failed, queue: running, avgMs: 0 };
    renderStats();
    renderTable(runs);
  } catch (e) { console.error('fetchRuns error:', e); }
}

async function fetchHealth() {
  try {
    const res = await fetch('/api/health');
    const h = await res.json();
    stats.avgMs = h.avg_task_duration_ms;
    renderStats();
  } catch (e) { /* ignore */ }
}

async function connectSSE() {
  const evtSource = new EventSource('/api/events');
  evtSource.onmessage = (e) => {
    try {
      const ev = JSON.parse(e.data);
      processEvent(ev);
      renderEventLog();
      // Refresh runs periodically on event
    } catch (err) { /* skip malformed */ }
  };
  evtSource.onerror = () => {
    console.warn('SSE disconnected, reconnecting in 3s…');
    setTimeout(connectSSE, 3000);
  };
}

function viewRun(runId) {
  alert('Run detail view: ' + runId + ' — logs at /d/agent-os/runs/' + runId + '/');
}

function cancelRun(runId) {
  if (confirm('Cancel run ' + runId + '?')) {
    alert('Cancel requested for ' + runId + ' (implement API call)');
  }
}

// Init
connectSSE();
fetchRuns();
fetchHealth();
setInterval(fetchRuns, 5000);
setInterval(fetchHealth, 15000);
</script>
</body>
</html>
"""

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import uvicorn
    # Create log dir
    HEALTH_LOG_DIR.mkdir(parents=True, exist_ok=True)
    uvicorn.run(app, host="0.0.0.0", port=8080, reload=False)
```

### Verification commands

```bash
# Install dependencies
pip install fastapi uvicorn httpx

# Start server (foreground test)
cd /d/agent-os && python dashboard.py

# Quick health check
curl http://localhost:8080/api/health | python -m json.tool

# Open dashboard
start http://localhost:8080
```

### NSSM Windows Service Registration

```powershell
# Run as Administrator
cd D:\agent-os
nssm install factory-dashboard "C:\Users\vanga\AppData\Local\Programs\Python\Python311\python.exe" "-m uvicorn dashboard:app --host 0.0.0.0 --port 8080"
nssm set factory-dashboard AppDirectory "D:\agent-os"
nssm set factory-dashboard AppStdout "D:\agent-os\logs\dashboard-stdout.log"
nssm set factory-dashboard AppStderr "D:\agent-os\logs\dashboard-stderr.log"
nssm set factory-dashboard AppRotateFiles 1
nssm set factory-dashboard AppRotateBytes 10485760  # 10 MB
nssm set factory-dashboard AppRotateSeconds 86400    # daily
nssm set factory-dashboard Start SERVICE_AUTO_START
nssm start factory-dashboard
```

---

## 3. Separate Log Layout

Every run and task gets its own directory tree. This structure enables targeted log access (no grepping through a single monolithic file), easy cleanup by age, and clean NFS/network share behavior.

```
D:/agent-os/
├── runs/
│   ├── R-2026-07-28-042/
│   │   ├── events.jsonl          # All events for this run (append-only, single file)
│   │   ├── summary.json          # Computed run summary (updated by checkpointer)
│   │   └── artifacts/            # Copied output files (optional, for audit)
│   └── R-2026-07-28-043/
│       └── events.jsonl
├── tasks/
│   ├── T-2026-0042/
│   │   ├── stdout.log            # Captured stdout from agent process
│   │   ├── stderr.log            # Captured stderr from agent process
│   │   ├── model.json            # Model invocation record (model ID, temperature, tokens, cost)
│   │   ├── result.json           # Task result (exit code, output paths, evidence hashes)
│   │   └── contract.json         # The typed task contract that was dispatched
│   └── T-2026-0043/
│       └── ...
├── logs/
│   ├── dashboard-stdout.log      # Dashboard server stdout (via NSSM rotation)
│   ├── dashboard-stderr.log      # Dashboard server stderr
│   ├── health.log                 # Periodic health poll records (see §6)
│   └── health-alerts.log         # Only alert events (queue > 10, failure spikes)
└── public/
    └── factory-events.json       # Legacy aggregate (backward compat)
```

### Task log writer contract

```bash
# Called by dispatch.sh after spawning agent
setup_task_logs() {
    local task_id="$1"
    local task_dir="/d/agent-os/tasks/${task_id}"
    mkdir -p "$task_dir"
    # Redirect agent stdout/stderr to task-specific logs
    exec 3>&1 4>&2  # save original stdout/stderr
    exec > >(tee "${task_dir}/stdout.log") 2> >(tee "${task_dir}/stderr.log" >&2)
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Task ${task_id} started"
}

# Save result after task completion
save_task_result() {
    local task_id="$1" exit_code="$2" model_id="$3" tokens="$4" cost="$5"
    local task_dir="/d/agent-os/tasks/${task_id}"
    cat > "${task_dir}/result.json" <<JSON
{
  "task_id": "${task_id}",
  "exit_code": ${exit_code},
  "output_paths": [],
  "evidence_hashes": {},
  "completed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
    cat > "${task_dir}/model.json" <<JSON
{
  "task_id": "${task_id}",
  "model_id": "${model_id}",
  "temperature": 0,
  "tokens_in": ${tokens:-0},
  "tokens_out": ${tokens:-0},
  "cost_usd": ${cost:-0},
  "provider": "opencode-go"
}
JSON
}
```

### Task directory creator (Python helper)

```python
"""scripts/ensure_task_dirs.py — called by dispatch.sh before spawning agent."""

import json
import sys
from pathlib import Path

BASE = Path("/d/agent-os")

def ensure(run_id: str, task_id: str, contract: dict | None = None):
    run_dir = BASE / "runs" / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    task_dir = BASE / "tasks" / task_id
    task_dir.mkdir(parents=True, exist_ok=True)

    # Ensure log files exist
    for name in ("stdout.log", "stderr.log"):
        f = task_dir / name
        if not f.exists():
            f.touch()

    # Write contract if provided
    if contract:
        (task_dir / "contract.json").write_text(json.dumps(contract, indent=2))

    print(f"Created {run_dir} and {task_dir}")

if __name__ == "__main__":
    ensure(sys.argv[1], sys.argv[2], json.loads(sys.argv[3]) if len(sys.argv) > 3 else None)
```

---

## 4. Real-Time Log Streaming via `tail -f` → SSE

A lightweight bridge that tails the latest task's `stdout.log` and pipes it to the dashboard SSE endpoint. This avoids overwhelming the main event stream with every log line.

### `stream_log.py` — Log streaming subprocess

```python
"""stream_log.py — Tail a task's stdout.log and push lines to a Redis pub/sub or
shared file that the dashboard SSE endpoint reads.

Usage:
    python stream_log.py T-2026-0042

The dashboard SSE endpoint /api/events already streams structured events.
For raw log lines, this process watches tasks/<task-id>/stdout.log and
appends lines as structured "log_line" events to the run's events.jsonl.
"""

import json
import os
import sys
import time
from pathlib import Path

TASKS_DIR = Path("/d/agent-os/tasks")
RUNS_DIR = Path("/d/agent-os/runs")

def tail_log(task_id: str):
    """Tail stdout.log and emit events for each new line."""
    log_file = TASKS_DIR / task_id / "stdout.log"
    if not log_file.exists():
        print(f"Log file not found: {log_file}", file=sys.stderr)
        sys.exit(1)

    # Determine run_id from task_id (convention: run prefix)
    run_id = f"R-{time.strftime('%Y-%m-%d')}-{task_id.split('-')[-1][:3]}"

    with open(log_file) as f:
        # Seek to end
        f.seek(0, 2)
        while True:
            line = f.readline()
            if line:
                line = line.rstrip("\n\r")
                ev = {
                    "schema_version": 2,
                    "time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    "run_id": run_id,
                    "task_id": task_id,
                    "event_type": "log_line",
                    "agent": None,
                    "tool": None,
                    "file_changed": None,
                    "gate": None,
                    "elapsed_ms": None,
                    "outcome": None,
                    "summary": line[:200],
                    "metadata": {"log_file": str(log_file)},
                }
                # Append to run's events.jsonl
                events_file = RUNS_DIR / run_id / "events.jsonl"
                try:
                    events_file.parent.mkdir(parents=True, exist_ok=True)
                    with open(events_file, "a") as ef:
                        ef.write(json.dumps(ev) + "\n")
                except OSError:
                    pass
                yield ev
            else:
                time.sleep(0.25)

if __name__ == "__main__":
    task_id = sys.argv[1] if len(sys.argv) > 1 else "T-latest"
    for ev in tail_log(task_id):
        pass  # consumed by the yield (or write to a pipe)
```

### SSE integration (in `dashboard.py`)

The main SSE endpoint already streams all events from `runs/<run-id>/events.jsonl`. Since `stream_log.py` writes `log_line` events to the same JSONL file, they appear in the dashboard automatically — no extra wiring needed.

For a dedicated log-stream endpoint:

```python
@app.get("/api/logs/{task_id}")
async def api_task_logs(task_id: str, request: Request):
    """SSE stream of a task's stdout.log in real time."""
    log_path = TASKS_DIR / task_id / "stdout.log"
    if not log_path.exists():
        return JSONResponse({"error": "Task not found"}, status_code=404)

    async def log_stream():
        with open(log_path) as f:
            f.seek(0, 2)  # start at end
            while True:
                if await request.is_disconnected():
                    break
                line = f.readline()
                if line:
                    yield f"data: {json.dumps({'type': 'stdout', 'line': line.rstrip()})}\n\n"
                else:
                    await asyncio.sleep(0.25)

    return StreamingResponse(
        log_stream(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "Connection": "keep-alive"},
    )
```

### Integration into `dashboard-bridge.sh`

Update the bridge to also copy to the `runs/` directory structure:

```bash
# In dashboard-bridge.sh — append to events.jsonl
run_id="R-$(date -u +%Y-%m-%d-%H%M%S)"
mkdir -p "/d/agent-os/runs/${run_id}"
cat /d/agent-os/public/factory-events.json \
  | python -c "
import json, sys
data = json.load(sys.stdin)
for ev in data.get('recent', []):
    print(json.dumps({
        'schema_version': 2,
        'time': ev.get('ts'),
        'run_id': ev.get('run_id'),
        'task_id': None,
        'event_type': 'Trace',
        'agent': ev.get('actor'),
        'tool': None,
        'file_changed': None,
        'gate': None,
        'elapsed_ms': None,
        'outcome': ev.get('outcome'),
        'summary': ev.get('summary'),
        'metadata': {}
    }))
" >> "/d/agent-os/runs/${run_id}/events.jsonl"
```

---

## 5. Health Metrics Endpoint

Implemented as `GET /api/health` in the dashboard server above (returns JSON). Here are the concrete fields and their derivations:

| Field | Type | Source | Derivation |
|---|---|---|---|
| `queue_depth` | int | Run state | Count of runs in `running` or `queued` state |
| `running_count` | int | Run state | Count of runs with `state == "running"` |
| `failed_count` | int | Run state | Count of runs with `state == "failed"` |
| `avg_task_duration_ms` | int | Events | Average of all `elapsed_ms` values where `event_type` ends with `_completed` or `_failed` |
| `token_usage_total` | int | Model.json sum | Sum of all `tasks/<id>/model.json` → `tokens_in + tokens_out` |
| `cost_usd_total` | float | Model.json sum | Sum of all `tasks/<id>/model.json` → `cost_usd` |
| `total_events` | int | Event count | Length of in-memory event list |
| `total_runs` | int | Unique run IDs | Unique run IDs across all events |
| `timestamp` | string | System clock | ISO-8601 UTC timestamp |

### Token cost aggregation (for accurate `token_usage_total` / `cost_usd_total`)

```python
# In FactoryState.replay_events() — aggregate from tasks/<id>/model.json
def _aggregate_costs(self):
    tasks_dir = TASKS_DIR
    if not tasks_dir.exists():
        return 0, 0.0
    total_tokens = 0
    total_cost = 0.0
    for task_dir in tasks_dir.iterdir():
        if not task_dir.is_dir():
            continue
        model_file = task_dir / "model.json"
        if model_file.exists():
            try:
                m = json.loads(model_file.read_text())
                total_tokens += m.get("tokens_in", 0) + m.get("tokens_out", 0)
                total_cost += m.get("cost_usd", 0.0)
            except (json.JSONDecodeError, OSError):
                pass
    return total_tokens, round(total_cost, 4)
```

---

## 6. PowerShell Health Monitor Script

Polls `/api/health` every 60 seconds, writes structured records to `D:/agent-os/logs/health.log`, and alerts on:
- `queue_depth > 10` — too many queued runs, pipeline is backing up
- `failed_count > previous_failed_count + 2` in a single poll — failure spike

### `monitor-health.ps1`

```powershell
<#
.SYNOPSIS
    AI Software Factory Health Monitor.
    Polls the dashboard /api/health endpoint every 60s.
    Writes to D:/agent-os/logs/health.log.
    Alerts on queue_depth > 10 or failed_count spike.
.DESCRIPTION
    Run as a background job or scheduled task.
    Logs are append-only, CSV compatible, auto-rotated at 10MB.
.NOTES
    Author: Factory Ops
    Run:    powershell -NoProfile -File D:\agent-os\scripts\monitor-health.ps1
#>

$ErrorActionPreference = "Stop"

# Configuration
$HealthUrl    = "http://localhost:8080/api/health"
$LogDir       = "D:\agent-os\logs"
$HealthLog    = "$LogDir\health.log"
$AlertLog     = "$LogDir\health-alerts.log"
$PollInterval = 60  # seconds
$MaxQueue     = 10
$SpikeThresh  = 2   # additional failed count before alert

# Ensure log directory
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

# Initialize alert state
$script:LastFailedCount = -1
$script:ConsecutiveErrors = 0
$script:TotalPolls = 0

function Write-HealthRecord {
    param(
        [string]$Timestamp,
        [int]$QueueDepth,
        [int]$RunningCount,
        [int]$FailedCount,
        [int]$AvgDurationMs,
        [int]$TokenTotal,
        [float]$CostTotal,
        [int]$StatusCode,
        [string]$ErrorMsg
    )
    # CSV-compatible format: timestamp|queue|running|failed|avg_ms|tokens|cost|status|error
    $record = "$Timestamp|$QueueDepth|$RunningCount|$FailedCount|$AvgDurationMs|$TokenTotal|$CostTotal|$StatusCode|$ErrorMsg"
    Add-Content -Path $HealthLog -Value $record -Encoding UTF8
}

function Write-Alert {
    param([string]$Message)
    $timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    $alert = "$timestamp|ALERT|$Message"
    Add-Content -Path $AlertLog -Value $alert -Encoding UTF8
    Write-Host "🔴 ALERT: $Message" -ForegroundColor Red
}

function Test-AlertThresholds {
    param($Health)
    $alerts = @()

    # Queue depth threshold
    if ($Health.queue_depth -gt $MaxQueue) {
        $alerts += "Queue depth $($Health.queue_depth) exceeds $MaxQueue"
    }

    # Failed count spike (only if we have a previous baseline)
    if ($script:LastFailedCount -ge 0) {
        $spike = $Health.failed_count - $script:LastFailedCount
        if ($spike -gt $SpikeThresh) {
            $alerts += "Failed count spike: $spike new failures (now $($Health.failed_count), was $($script:LastFailedCount))"
        }
    }
    $script:LastFailedCount = $Health.failed_count

    return $alerts
}

function Invoke-HealthCheck {
    $timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    $errorMsg = ""
    $statusCode = 0

    try {
        $response = Invoke-WebRequest -Uri $HealthUrl -Method GET -TimeoutSec 10 -UseBasicParsing
        $statusCode = [int]$response.StatusCode
        $health = $response.Content | ConvertFrom-Json

        Write-HealthRecord -Timestamp $timestamp `
            -QueueDepth $health.queue_depth `
            -RunningCount $health.running_count `
            -FailedCount $health.failed_count `
            -AvgDurationMs $health.avg_task_duration_ms `
            -TokenTotal $health.token_usage_total `
            -CostTotal $health.cost_usd_total `
            -StatusCode $statusCode `
            -ErrorMsg ""

        # Check thresholds
        $alerts = Test-AlertThresholds $health
        foreach ($alert in $alerts) {
            Write-Alert $alert
        }

        # Health summary to console
        Write-Host "[$timestamp] queue=$($health.queue_depth) running=$($health.running_count) failed=$($health.failed_count) avg=${($health.avg_task_duration_ms)}ms tokens=$($health.token_usage_total)" -ForegroundColor Green

        $script:ConsecutiveErrors = 0
        return $true
    }
    catch {
        $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        $errorMsg = $_.Exception.Message -replace '[|]', '/'  # sanitize for CSV
        Write-HealthRecord -Timestamp $timestamp -QueueDepth 0 -RunningCount 0 -FailedCount 0 -AvgDurationMs 0 -TokenTotal 0 -CostTotal 0 -StatusCode $statusCode -ErrorMsg $errorMsg

        $script:ConsecutiveErrors++
        if ($script:ConsecutiveErrors -ge 3) {
            Write-Alert "Dashboard unreachable for $($script:ConsecutiveErrors) consecutive polls: $errorMsg"
        }
        Write-Host "[$timestamp] ❌ Error: $errorMsg" -ForegroundColor Red
        return $false
    }
}

# Auto-rotate health.log at 10MB
function Rotate-Log {
    param([string]$Path)
    if (Test-Path $Path) {
        $len = (Get-Item $Path).Length
        if ($len -gt 10MB) {
            $rotated = "$Path.$(Get-Date -Format 'yyyyMMddHHmmss').bak"
            Move-Item $Path $rotated -Force
            Write-Host "Rotated $Path → $rotated" -ForegroundColor Yellow
        }
    }
}

# ── Main Loop ──────────────────────────────────────────────────────────────

Write-Host "🏭 AI Software Factory Health Monitor" -ForegroundColor Cyan
Write-Host "   Polling:  $HealthUrl"
Write-Host "   Interval: ${PollInterval}s"
Write-Host "   Log:      $HealthLog"
Write-Host "   Alerts:   $AlertLog"
Write-Host "   Queued:   >$MaxQueue triggers alert"
Write-Host "   Spikes:   >$SpikeThresh new failures triggers alert"
Write-Host "── Press Ctrl+C to stop ──" -ForegroundColor Gray

# Write CSV header if file is new
if (-not (Test-Path $HealthLog)) {
    Add-Content -Path $HealthLog -Value "#timestamp|queue_depth|running_count|failed_count|avg_task_duration_ms|token_usage_total|cost_usd_total|status_code|error" -Encoding UTF8
}

# Infinite polling loop
while ($true) {
    Rotate-Log $HealthLog
    Rotate-Log $AlertLog
    Invoke-HealthCheck
    $script:TotalPolls++
    Start-Sleep -Seconds $PollInterval
}
```

### Install as Windows Scheduled Task (runs without user login)

```powershell
# Run as Administrator
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -File D:\agent-os\scripts\monitor-health.ps1"
$trigger = New-ScheduledTaskTrigger -AtStartup -RepetitionInterval (New-TimeSpan -Minutes 1)
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount
Register-ScheduledTask -TaskName "FactoryHealthMonitor" `
    -Action $action -Trigger $trigger -Principal $principal -Force

# Test
Start-ScheduledTask -TaskName "FactoryHealthMonitor"
Get-ScheduledTask -TaskName "FactoryHealthMonitor" | Get-ScheduledTaskInfo
```

### Health log format (CSV pipe-delimited, one poll per line)

```
#timestamp|queue_depth|running_count|failed_count|avg_task_duration_ms|token_usage_total|cost_usd_total|status_code|error
2026-07-28T14:30:00Z|2|2|1|3420|150000|2.45|200|
2026-07-28T14:31:00Z|2|2|1|3420|150000|2.45|200|
2026-07-28T14:32:00Z|5|5|3|4100|155000|2.55|200|
2026-07-28T14:32:00Z|ALERT|Failed count spike: 2 new failures (now 3, was 1)
```

---

## Implementation Roadmap

| Phase | What | Effort | Depends On |
|---|---|---|---|
| **P0** | Deploy `dashboard.py` (single file, uvicorn), verify `/api/health` and `/` HTML render | 30 min | Python + fastapi installed |
| **P0** | Register as NSSM service `factory-dashboard`, test auto-start | 10 min | P0 dashboard working |
| **P1** | Migrate `dashboard-bridge.sh` → write to `runs/<run-id>/events.jsonl` with v2 schema | 1 hr | Factory scripts running |
| **P1** | Wire `dispatch.sh` to call `ensure_task_dirs.py` before spawning agent | 30 min | P1 schema migration |
| **P2** | Deploy `monitor-health.ps1` as scheduled task, verify `health.log` written | 20 min | P0 dashboard port 8080 |
| **P2** | Wire task log capture: agent stdout/stderr → `tasks/<id>/stdout.log + stderr.log` | 1 hr | P1 dispatch enhancement |
| **P2** | Add `/api/logs/{task_id}` SSE endpoint (raw log streaming) | 15 min | P2 task log capture |
| **P3** | Add token cost tracking: `model.json` written by dispatch.sh after each task | 30 min | P2 task log capture |
| **P3** | Add `view` and `cancel` action endpoints to dashboard | 1 hr | P0 dashboard deployed |
| **P3** | Set up health-alert notification channel (email/Teams/Discord webhook) | 1 hr | P2 health monitor |

### Verification checklist

```
□ dashboard.py serves HTML at http://localhost:8080/
□ /api/health returns all 7 metric fields
□ SSE stream delivers events as they're written to runs/<id>/events.jsonl
□ NSSM service starts on boot and survives reboot
□ health.log shows consistent 60s poll records
□ queue_depth > 10 triggers alert record in health-alerts.log
□ failed_count spike > +2 triggers alert
□ self-healing: dashboard recovers from NSSM restart without data loss
```
