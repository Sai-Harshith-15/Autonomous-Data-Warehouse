#!/usr/bin/env bash
set -euo pipefail

# factory-daemon.sh — Main loop for NSSM/Hermes Factory service.
# Runs dispatch in a polling loop, manages lifecycle.
# Usage: factory-daemon.sh [--once]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

export HARNESS_DB="${HARNESS_DB:-D:/agent-os/harness.db}"
export POOL_CONFIG="${POOL_CONFIG:-D:/hermes-factory/config/resource-pool.yaml}"
export DASHBOARD_PORT="${DASHBOARD_PORT:-8199}"

once=false
[[ "${1:-}" == "--once" ]] && once=true

# Create log directory
mkdir -p /d/agent-os/logs
LOG_FILE="/d/agent-os/logs/factory-daemon.log"

log() {
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    echo "[$ts] $*" | tee -a "$LOG_FILE"
}

log "Factory daemon starting (REPO: $REPO_ROOT, DB: $HARNESS_DB)"

# Check DB schema
if [[ ! -f "$HARNESS_DB" ]]; then
    log "ERROR: $HARNESS_DB not found. Run schema first."
    if $once; then exit 1; fi
fi

# ─── Start Dashboard (background) ──────────────────────────
start_dashboard() {
    if lsof -i ":${DASHBOARD_PORT}" &>/dev/null 2>&1; then
        log "Dashboard already running on port $DASHBOARD_PORT"
        return
    fi
    log "Starting dashboard on port $DASHBOARD_PORT..."
    nohup python "$SCRIPT_DIR/dashboard.py" >> /d/agent-os/logs/dashboard.log 2>&1 &
    DASHBOARD_PID=$!
    log "Dashboard PID: $DASHBOARD_PID"
}

start_dashboard

# ─── Main Loop ──────────────────────────────────────────────
POLL_INTERVAL="${POLL_INTERVAL:-30}"  # seconds

while true; do
    # Check for pending runs in DB
    pending_runs=$(python -c "
import sqlite3
conn = sqlite3.connect('$HARNESS_DB', timeout=10)
rows = conn.execute(\"SELECT run_id FROM runs WHERE status='pending'\").fetchall()
conn.close()
for r in rows:
    print(r[0])
" 2>/dev/null || true)

    if [[ -n "$pending_runs" ]]; then
        while IFS= read -r run_id; do
            if [[ -z "$run_id" ]]; then continue; fi
            log "Dispatching pending run: $run_id"
            bash "$SCRIPT_DIR/dispatch.sh" --run-id "$run_id"
            log "Run $run_id complete"
        done <<< "$pending_runs"
    else
        log "No pending runs. Idle (poll every ${POLL_INTERVAL}s)"
    fi

    $once && { log "Daemon: --once specified, exiting"; exit 0; }
    sleep "$POLL_INTERVAL"
done
