#!/usr/bin/env bash
set -euo pipefail

# approve.sh — human approval gate for dangerous operations (M7)
# Usage: approve.sh --task-id <T-...> [--by <who>] [--reason "..."] [--reject]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

task_id=""
approved_by=""
reason=""
reject=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task-id) task_id="$2"; shift 2 ;;
        --by) approved_by="$2"; shift 2 ;;
        --reason) reason="$2"; shift 2 ;;
        --reject) reject=true; shift ;;
        *) shift ;;
    esac
done
[[ -z "$task_id" ]] && { echo "Usage: approve.sh --task-id <T-...> [--by <who>] [--reason ...] [--reject]" >&2; exit 1; }

approved_by="${approved_by:-human}"
reason="${reason:-Approved}"

approval_dir="approvals"
pending_file="${approval_dir}/pending/${task_id}.json"

if $reject; then
    echo "[approve] ✗ REJECTED: $task_id by $approved_by — $reason"
    outcome="rejected"
else
    echo "[approve] ✓ APPROVED: $task_id by $approved_by — $reason"
    outcome="approved"
fi

# Move from pending to decided
mkdir -p "${approval_dir}/decided"
if [[ -f "$pending_file" ]]; then
    mv "$pending_file" "${approval_dir}/decided/${task_id}-${outcome}.json" 2>/dev/null || true
fi

# Record decision
python -c "
import json, os
from datetime import datetime, timezone
decision = {
    'task_id': '$task_id',
    'decision': '$outcome',
    'approved_by': '$approved_by',
    'reason': '$reason',
    'timestamp': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
}
os.makedirs('${approval_dir}/decided', exist_ok=True)
with open('${approval_dir}/decided/${task_id}-decision.json', 'w') as f:
    json.dump(decision, f, indent=2)
"

# Trace
bash "$REPO_ROOT/scripts/trace.sh" \
    --summary "ApprovalDecided: $task_id → $outcome by $approved_by" \
    --outcome "$([[ "$outcome" == "approved" ]] && echo success || echo failure)" \
    --task-id "$task_id" \
    --actor "approval-gate"

echo "[approve] ✓ Decision recorded"
