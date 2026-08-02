#!/usr/bin/env python3
"""
dashboard.py — FastAPI SSE dashboard for AI Software Factory.
Serves live event stream, run status, and health metrics.

Usage:
  uvicorn dashboard:app --host 127.0.0.1 --port 8199 --reload
  python dashboard.py   # (standalone fallback)
"""

import json, os, time, asyncio
from datetime import datetime, timezone
from pathlib import Path
from collections import defaultdict, deque

try:
    from fastapi import FastAPI, Request, HTTPException
    from fastapi.responses import HTMLResponse, StreamingResponse, JSONResponse
    from fastapi.middleware.cors import CORSMiddleware
except ImportError:
    print("ERROR: FastAPI not installed. Run: pip install fastapi uvicorn")
    exit(1)

# ─── Config ──────────────────────────────────────────────────────────────
REPO_ROOT = Path(__file__).resolve().parent.parent
FACTORY_HOME = Path(os.environ.get("FACTORY_HOME", REPO_ROOT / ".factory"))
DB_PATH = os.environ.get("HARNESS_DB", str(FACTORY_HOME / "state" / "harness.db"))
RUNS_DIR = Path(os.environ.get("RUNS_DIR", FACTORY_HOME / "runs"))

app = FastAPI(title="AI Software Factory Dashboard", version="2.0.0")
app.add_middleware(CORSMiddleware, allow_origins=["http://127.0.0.1:8199", "http://localhost:8199"], allow_credentials=False, allow_methods=["GET"], allow_headers=["Content-Type"])

# ─── In-memory event ring buffer (last 1000 events) ─────────────
event_buffer = deque(maxlen=1000)
sse_clients = set()

try:
    import sqlite3
    HAVE_DB = True
except ImportError:
    HAVE_DB = False

def db_conn():
    if not HAVE_DB:
        return None
    try:
        conn = sqlite3.connect(DB_PATH, timeout=10)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        return conn
    except Exception:
        return None

def load_events_from_log(run_id, limit=100):
    """Load events from runs/<run-id>/events.jsonl."""
    ev_path = RUNS_DIR / str(run_id) / "events.jsonl"
    if not ev_path.exists():
        return []
    events = []
    try:
        with open(ev_path) as f:
            for line in f:
                if line.strip():
                    events.append(json.loads(line))
    except (json.JSONDecodeError, IOError):
        pass
    return events[-limit:]

def load_run_from_db(run_id):
    conn = db_conn()
    if not conn:
        return None
    try:
        row = conn.execute("SELECT * FROM runs WHERE run_id=?", (run_id,)).fetchone()
        return dict(row) if row else None
    finally:
        conn.close()

def load_all_runs(limit=20):
    conn = db_conn()
    if not conn:
        return []
    try:
        rows = conn.execute("""SELECT run_id, project, status, created_at, started_at,
                                finished_at, elapsed_ms, done_tasks, failed_tasks, total_tasks
                                FROM runs ORDER BY created_at DESC LIMIT ?""", (limit,)).fetchall()
        return [dict(r) for r in rows]
    except Exception:
        return []
    finally:
        conn.close()

def compute_health():
    """Compute health metrics from DB."""
    conn = db_conn()
    if not conn:
        return {"error": "DB unavailable", "status": "degraded"}
    try:
        # Queue depth: pending tasks
        queue_depth = conn.execute("SELECT COUNT(*) as c FROM tasks WHERE status='pending'").fetchone()[0]
        running_count = conn.execute("SELECT COUNT(*) as c FROM tasks WHERE status='running'").fetchone()[0]
        failed_count = conn.execute("SELECT COUNT(*) as c FROM tasks WHERE status='failed'").fetchone()[0]
        
        # Average task duration
        avg_row = conn.execute("SELECT AVG(elapsed_ms) FROM tasks WHERE elapsed_ms IS NOT NULL").fetchone()
        avg_duration = avg_row[0] if avg_row and avg_row[0] else 0
        
        # Token and cost totals
        cost_row = conn.execute("SELECT SUM(total_cost_usd), SUM(total_tokens) FROM runs").fetchone()
        cost_usd = cost_row[0] or 0
        total_tokens = cost_row[1] or 0
        
        total_runs = conn.execute("SELECT COUNT(*) FROM runs").fetchone()[0]
        total_events = conn.execute("SELECT COUNT(*) FROM events").fetchone()[0]
        
        return {
            "status": "healthy",
            "queue_depth": queue_depth,
            "running_count": running_count,
            "failed_count": failed_count,
            "avg_task_duration_ms": round(avg_duration, 1) if avg_duration else 0,
            "cost_usd_total": round(cost_usd, 4),
            "token_usage_total": total_tokens,
            "total_runs": total_runs,
            "total_events": total_events,
            "timestamp": datetime.now(timezone.utc).isoformat()
        }
    except Exception as e:
        return {"status": "degraded", "error": str(e)}
    finally:
        conn.close()

# ─── Routes ──────────────────────────────────────────────────────────────

@app.get("/api/health")
async def health():
    return JSONResponse(compute_health())

@app.get("/api/runs")
async def list_runs():
    runs = load_all_runs(20)
    return JSONResponse(runs)

@app.get("/api/runs/{run_id}")
async def get_run(run_id: str):
    run = load_run_from_db(run_id)
    if not run:
        raise HTTPException(404, f"Run {run_id} not found")
    # Load events for this run
    events = load_events_from_log(run_id, 200)
    run["events"] = events
    return JSONResponse(run)

@app.get("/api/events")
async def stream_events(request: Request):
    """SSE endpoint: streams new events as they're written to JSONL."""
    async def event_generator():
        # Replay last 50 events
        for buf in list(event_buffer)[-50:]:
            yield f"data: {json.dumps(buf)}\n\n"
        
        # Tail runs/*/events.jsonl files
        seen_files = set()
        last_positions = {}
        
        while True:
            if await request.is_disconnected():
                break
            try:
                # Check all run event files for new lines
                if RUNS_DIR.exists():
                    for run_dir in sorted(RUNS_DIR.iterdir()):
                        if not run_dir.is_dir():
                            continue
                        ev_file = run_dir / "events.jsonl"
                        if not ev_file.exists():
                            continue
                        fpath = str(ev_file)
                        if fpath not in last_positions:
                            last_positions[fpath] = 0
                            seen_files.add(fpath)
                        
                        try:
                            with open(ev_file) as f:
                                f.seek(last_positions[fpath])
                                for line in f:
                                    if line.strip():
                                        ev = json.loads(line)
                                        event_buffer.append(ev)
                                        yield f"data: {json.dumps(ev)}\n\n"
                                last_positions[fpath] = f.tell()
                        except (IOError, json.JSONDecodeError):
                            pass
            except Exception:
                pass
            await asyncio.sleep(1)
    
    return StreamingResponse(event_generator(), media_type="text/event-stream")

@app.get("/api/logs/{task_id}")
async def stream_task_logs(task_id: str, request: Request):
    """SSE endpoint: tail a specific task's stdout.log."""
    async def log_generator():
        # Search all runs for this task
        log_path = None
        if RUNS_DIR.exists():
            for run_dir in RUNS_DIR.iterdir():
                if not run_dir.is_dir():
                    continue
                candidate = run_dir / "tasks" / task_id / "stdout.log"
                if candidate.exists():
                    log_path = candidate
                    break
        
        if not log_path:
            yield f"data: {json.dumps({'error': f'Task {task_id} not found'})}\n\n"
            return
        
        # Send existing content
        try:
            with open(log_path) as f:
                content = f.read()
                yield f"data: {json.dumps({'task_id': task_id, 'content': content, 'type': 'snapshot'})}\n\n"
                last_pos = f.tell()
        except IOError:
            yield f"data: {json.dumps({'error': 'Cannot read log'})}\n\n"
            return
        
        # Tail new content
        while True:
            if await request.is_disconnected():
                break
            try:
                with open(log_path) as f:
                    f.seek(last_pos)
                    new_content = f.read()
                    if new_content:
                        yield f"data: {json.dumps({'task_id': task_id, 'content': new_content, 'type': 'tail'})}\n\n"
                        last_pos = f.tell()
            except IOError:
                break
            await asyncio.sleep(2)
    
    return StreamingResponse(log_generator(), media_type="text/event-stream")

# ─── Static HTML Dashboard ───────────────────────────────────────────────

DASHBOARD_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>AI Software Factory Dashboard</title>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: 'Segoe UI', system-ui, sans-serif; background: #0a0a0f; color: #e0e0e0; padding: 20px; }
h1 { color: #00e5ff; font-size: 1.5rem; margin-bottom: 8px; }
.subtitle { color: #888; font-size: 0.85rem; margin-bottom: 20px; }
.stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(130px, 1fr)); gap: 12px; margin-bottom: 24px; }
.stat-card { background: #14141f; border: 1px solid #2a2a3a; border-radius: 8px; padding: 12px 16px; }
.stat-card .label { color: #888; font-size: 0.7rem; text-transform: uppercase; letter-spacing: 0.5px; }
.stat-card .value { color: #fff; font-size: 1.4rem; font-weight: 700; margin-top: 4px; }
.stat-card .value.green { color: #00e676; }
.stat-card .value.red { color: #ff5252; }
.stat-card .value.cyan { color: #00e5ff; }
.stat-card .value.yellow { color: #ffd740; }
table { width: 100%; border-collapse: collapse; background: #14141f; border-radius: 8px; overflow: hidden; }
th { text-align: left; padding: 10px 14px; background: #1a1a2e; color: #00e5ff; font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.5px; border-bottom: 1px solid #2a2a3a; }
td { padding: 10px 14px; border-bottom: 1px solid #1e1e2e; font-size: 0.85rem; }
tr:hover { background: #1a1a2e; }
.status { display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 0.75rem; font-weight: 600; }
.status.running { background: #1b5e20; color: #81c784; }
.status.succeeded { background: #0d3315; color: #a5d6a7; }
.status.failed { background: #4a1a1a; color: #ef9a9a; }
.status.pending { background: #2a2a3a; color: #b0b0b0; }
.status.blocked { background: #4a3a0a; color: #ffd740; }
.status.cancelled { background: #3a1a2a; color: #ce93d8; }
.events-panel { margin-top: 24px; background: #14141f; border: 1px solid #2a2a3a; border-radius: 8px; padding: 16px; max-height: 300px; overflow-y: auto; }
.events-panel .title { color: #00e5ff; font-size: 0.8rem; text-transform: uppercase; margin-bottom: 8px; }
.event-entry { padding: 4px 0; border-bottom: 1px solid #1a1a2a; font-size: 0.8rem; font-family: 'Cascadia Code', 'Fira Code', monospace; }
.event-entry .ts { color: #666; }
.event-entry .type { font-weight: 600; }
.event-entry .type.run_started { color: #00e5ff; }
.event-entry .type.task_started { color: #81c784; }
.event-entry .type.task_completed { color: #a5d6a7; }
.event-entry .type.task_failed { color: #ef9a9a; }
.event-entry .type.gate_passed { color: #a5d6a7; }
.event-entry .type.gate_failed { color: #ef9a9a; }
.refresh-note { color: #555; font-size: 0.7rem; margin-top: 8px; }
</style>
</head>
<body>
<h1>▪ AI Software Factory</h1>
<div class="subtitle">Real-time pipeline dashboard — events stream live via SSE</div>

<div class="stats" id="stats">
  <div class="stat-card"><div class="label">Queue Depth</div><div class="value yellow" id="queue-depth">—</div></div>
  <div class="stat-card"><div class="label">Running</div><div class="value cyan" id="running-count">—</div></div>
  <div class="stat-card"><div class="label">Failed</div><div class="value red" id="failed-count">—</div></div>
  <div class="stat-card"><div class="label">Avg Duration</div><div class="value" id="avg-duration">—</div></div>
  <div class="stat-card"><div class="label">Total Events</div><div class="value" id="total-events">—</div></div>
  <div class="stat-card"><div class="label">Cost (USD)</div><div class="value" id="total-cost">—</div></div>
</div>

<table>
<thead><tr><th>Run ID</th><th>Project</th><th>Status</th><th>Progress</th><th>Elapsed</th><th>Created</th></tr></thead>
<tbody id="runs-tbody"></tbody>
</table>

<div class="events-panel" id="events-panel">
<div class="title">Live Events</div>
<div id="event-stream"></div>
</div>
<div class="refresh-note">* Status updates every 5s | Events stream live</div>

<script>
const runsBody = document.getElementById('runs-tbody');
const eventStream = document.getElementById('event-stream');

// Refresh runs + stats every 5s
async function refresh() {
  try {
    const [runsResp, healthResp] = await Promise.all([
      fetch('/api/runs'),
      fetch('/api/health')
    ]);
    const runs = await runsResp.json();
    const health = await healthResp.json();

    document.getElementById('queue-depth').textContent = health.queue_depth ?? '—';
    document.getElementById('running-count').textContent = health.running_count ?? '—';
    document.getElementById('failed-count').textContent = health.failed_count ?? '—';
    document.getElementById('avg-duration').textContent = health.avg_task_duration_ms ? (health.avg_task_duration_ms + 'ms') : '—';
    document.getElementById('total-events').textContent = health.total_events ?? '—';
    document.getElementById('total-cost').textContent = health.cost_usd_total ? '$' + health.cost_usd_total.toFixed(2) : '—';

    if (runs.length === 0) {
      runsBody.innerHTML = '<tr><td colspan="6" style="text-align:center;color:#666;padding:20px;">No pipeline runs yet. Start one with dispatch.sh</td></tr>';
      return;
    }
    runsBody.innerHTML = runs.map(r => {
      const statusLower = (r.status || 'pending').toLowerCase();
      return `<tr>
        <td><code>${r.run_id}</code></td>
        <td>${r.project || '—'}</td>
        <td><span class="status ${statusLower}">${r.status || 'pending'}</span></td>
        <td>${r.done_tasks ?? 0}/${r.total_tasks ?? '—'}</td>
        <td>${r.elapsed_ms ? (r.elapsed_ms/1000).toFixed(1) + 's' : '—'}</td>
        <td>${r.created_at ? r.created_at.slice(0, 19).replace('T', ' ') : '—'}</td>
      </tr>`;
    }).join('');
  } catch (e) {
    // Connection issue — show degraded
  }
}
refresh();
setInterval(refresh, 5000);

// SSE event stream
let lastEventCount = 0;
function connectSSE() {
  const evtSource = new EventSource('/api/events');
  evtSource.onmessage = (e) => {
    try {
      const ev = JSON.parse(e.data);
      const ts = ev.time ? ev.time.slice(11, 19) : '--:--:--';
      const type = ev.event_type || 'event';
      const summary = ev.summary || '';
      const entry = document.createElement('div');
      entry.className = 'event-entry';
      entry.innerHTML = `<span class="ts">${ts}</span> <span class="type ${type}">${type}</span> ${summary}`;
      eventStream.prepend(entry);
      lastEventCount++;
      // Keep max 200
      while (eventStream.children.length > 200) {
        eventStream.removeChild(eventStream.lastChild);
      }
    } catch (e) {}
  };
  evtSource.onerror = () => {
    // Reconnect after 3s
    evtSource.close();
    setTimeout(connectSSE, 3000);
  };
}
connectSSE();
</script>
</body>
</html>"""

@app.get("/")
async def dashboard():
    return HTMLResponse(DASHBOARD_HTML)

# ─── Main ────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import uvicorn
    port = int(os.environ.get("DASHBOARD_PORT", "8199"))
    host = os.environ.get("DASHBOARD_HOST", "127.0.0.1")
    print(f"[dashboard] Starting on {host}:{port}")
    uvicorn.run(app, host=host, port=port, log_level="info")
