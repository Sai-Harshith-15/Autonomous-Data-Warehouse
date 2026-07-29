#!/usr/bin/env bash
set -euo pipefail

# trace.sh v2 — append a JSONL event to both runs/<run-id>/events.jsonl AND SQLite harness.db
# Usage: trace.sh --run-id <R-...> --event-type <type> [--task-id <T-...>] --summary "..."
#   [--outcome <outcome>] [--agent <agent>] [--tool <tool>]
#   [--file-changed <path>] [--gate <name>] [--elapsed-ms <ms>] [--metadata <json>]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

run_id=""
task_id=""
event_type=""
summary=""
outcome=""
agent=""
tool=""
file_changed=""
gate=""
elapsed_ms=""
metadata="{}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run-id)       run_id="$2";      shift 2 ;;
        --task-id)      task_id="$2";     shift 2 ;;
        --event-type)   event_type="$2";  shift 2 ;;
        --summary)      summary="$2";     shift 2 ;;
        --outcome)      outcome="$2";     shift 2 ;;
        --agent)        agent="$2";       shift 2 ;;
        --tool)         tool="$2";        shift 2 ;;
        --file-changed) file_changed="$2"; shift 2 ;;
        --gate)         gate="$2";        shift 2 ;;
        --elapsed-ms)   elapsed_ms="$2";  shift 2 ;;
        --metadata)     metadata="$2";    shift 2 ;;
        *) echo "Unknown: $1" >&2; exit 1 ;;
    esac
done

[[ -z "$run_id" || -z "$event_type" ]] && { echo "Usage: trace.sh --run-id <R-...> --event-type <type> --summary <...>" >&2; exit 1; }

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
today=$(date -u +"%Y-%m-%d")

# Build JSON payload using Python with sys.argv (avoids bash quoting issues)
payload=$(python -c '
import json, sys
obj = {
    "schema_version": 2,
    "time": sys.argv[1],
    "run_id": sys.argv[2],
    "task_id": sys.argv[3] if sys.argv[3] != "-" else None,
    "event_type": sys.argv[4],
    "agent": sys.argv[5] if sys.argv[5] != "-" else None,
    "tool": sys.argv[6] if sys.argv[6] != "-" else None,
    "file_changed": sys.argv[7] if sys.argv[7] != "-" else None,
    "gate": sys.argv[8] if sys.argv[8] != "-" else None,
    "elapsed_ms": int(sys.argv[9]) if sys.argv[9] != "-" else None,
    "outcome": sys.argv[10] if sys.argv[10] != "-" else None,
    "summary": sys.argv[11],
    "metadata": json.loads(sys.argv[12]) if sys.argv[12] != "-" else {}
}
obj = {k: v for k, v in obj.items() if v is not None}
print(json.dumps(obj, separators=(",", ":")))
' "$ts" "$run_id" "${task_id:--}" "$event_type" "${agent:--}" "${tool:--}" "${file_changed:--}" "${gate:--}" "${elapsed_ms:--}" "${outcome:--}" "$summary" "${metadata:--}")

# 1. Write to run-specific JSONL
runs_dir="/d/agent-os/runs/${run_id}"
mkdir -p "$runs_dir"
echo "$payload" >> "${runs_dir}/events.jsonl"

# 2. Write to daily events file for backward compat
mkdir -p "$REPO_ROOT/events"
echo "$payload" >> "$REPO_ROOT/events/${today}.jsonl"

# 3. Write to SQLite if possible
python -c '
import json, sys, os
try:
    DB = os.environ.get("HARNESS_DB", "D:/agent-os/harness.db")
    import sqlite3
    conn = sqlite3.connect(DB, timeout=10)
    conn.execute("PRAGMA journal_mode=WAL")
    obj = json.loads(sys.argv[1])
    conn.execute("""INSERT INTO events (schema_version, time, run_id, task_id, event_type,
                    agent, tool, file_changed, gate, elapsed_ms, outcome, summary, metadata)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (obj.get("schema_version", 2), obj.get("time"), obj.get("run_id"),
                 obj.get("task_id"), obj.get("event_type"), obj.get("agent"),
                 obj.get("tool"), obj.get("file_changed"), obj.get("gate"),
                 obj.get("elapsed_ms"), obj.get("outcome"), obj.get("summary"),
                 json.dumps(obj.get("metadata", {}))))
    conn.commit()
    conn.close()
except Exception as e:
    pass
' "$payload" 2>/dev/null || true

exit 0
