#!/usr/bin/env bash
set -euo pipefail

# dispatch.sh v4 — calls _dag_scheduler.py to manage full DAG lifecycle
# Usage: dispatch.sh --run-id <R-...> [--dry-run]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

run_id=""
dry_run=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run-id)  run_id="$2";  shift 2 ;;
        --dry-run) dry_run=true; shift ;;
        *) echo "Unknown: $1" >&2; exit 1 ;;
    esac
done

[[ -z "$run_id" ]] && { echo "Usage: dispatch.sh --run-id <R-...> [--dry-run]" >&2; exit 1; }

# Verify DB exists
if [[ ! -f "D:/agent-os/harness.db" ]]; then
    echo "[dispatch] ERROR: harness.db not found. Run schema first."
    exit 1
fi

echo "[dispatch v4] Starting run: $run_id"
echo "[dispatch v4] Scheduler: _dag_scheduler.py"

# Call the Python DAG scheduler
extra_args=""
$dry_run && extra_args="--dry-run"

python "$SCRIPT_DIR/_dag_scheduler.py" --run-id "$run_id" $extra_args

exit_code=$?

if [[ $exit_code -eq 0 ]]; then
    echo "[dispatch v4] ✓ Run $run_id completed successfully"
else
    echo "[dispatch v4] ⚠ Run $run_id completed with failures (exit: $exit_code)"
fi

exit $exit_code
