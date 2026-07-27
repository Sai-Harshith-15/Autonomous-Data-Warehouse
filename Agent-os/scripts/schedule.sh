#!/usr/bin/env bash
set -euo pipefail

# schedule.sh — DAG topological scheduler (M3, Windows-safe)
# Usage: schedule.sh --dag <dag.json> [--run-id <R-...>]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

dag_file=""
run_id="R-$(date -u +%Y-%m-%d)-001"
while [[ $# -gt 0 ]]; do case "$1" in --dag) dag_file="$2"; shift 2 ;; --run-id) run_id="$2"; shift 2 ;; *) shift ;; esac; done
[[ -z "$dag_file" ]] && { echo "Usage: schedule.sh --dag <dag.json>" >&2; exit 1; }

dag_win=$(cygpath -m "$dag_file" 2>/dev/null || echo "$dag_file")
repo_win=$(cygpath -m "$REPO_ROOT" 2>/dev/null || echo "$REPO_ROOT")

python scripts/_schedule_worker.py "$dag_file" "$run_id" "$REPO_ROOT"
exit_code=$?

bash "$REPO_ROOT/scripts/trace.sh" --summary "ScheduleComplete: $run_id" --outcome "$([[ $exit_code -eq 0 ]] && echo success || echo failure)" --actor "scheduler"
exit $exit_code
