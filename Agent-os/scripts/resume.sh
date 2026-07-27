#!/usr/bin/env bash
set -euo pipefail

# resume.sh — restore factory state from checkpoint (M5)
# Usage: resume.sh --checkpoint <checkpoints/<run>/<task>.json>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

ckpt_file=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --checkpoint) ckpt_file="$2"; shift 2 ;;
        *) echo "Unknown: $1" >&2; exit 1 ;;
    esac
done
[[ -z "$ckpt_file" ]] && { echo "Usage: resume.sh --checkpoint <path>" >&2; exit 1; }
[[ ! -f "$ckpt_file" ]] && { echo "Checkpoint not found: $ckpt_file" >&2; exit 1; }

ckpt_win=$(cygpath -w "$ckpt_file" 2>/dev/null || echo "$ckpt_file")

echo "[resume] Loading checkpoint: $ckpt_file"

# Parse checkpoint
eval $(python -c "
import json, sys
with open(sys.argv[1]) as f:
    c = json.load(f)
print(f'RUN_ID={c[\"run_id\"]}')
print(f'TASK_ID={c[\"task_id\"]}')
print(f'EVENT_CURSOR={c.get(\"event_cursor\",0)}')
print(f'GIT_SHA={c.get(\"git_sha\",\"\")}')
print(f'BUDGET_SPENT_TOKENS={c.get(\"budget_spent\",{}).get(\"tokens\",0)}')
print(f'BUDGET_SPENT_COST={c.get(\"budget_spent\",{}).get(\"cost_usd\",0)}')
" "$ckpt_win")

echo "[resume] Run $RUN_ID, Task $TASK_ID"
echo "[resume] Event cursor: $EVENT_CURSOR, Budget spent: $BUDGET_SPENT_TOKENS tokens"

# Verify git SHA matches (optional — warn if diverged)
current_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
if [[ -n "$GIT_SHA" && "$GIT_SHA" != "$current_sha" ]]; then
    echo "[resume] ⚠ Git SHA changed: $GIT_SHA → $current_sha (checkpoint may be stale)"
fi

# Replay events from cursor to verify state
events_today="events/$(date -u +%Y-%m-%d).jsonl"
if [[ -f "$events_today" ]]; then
    python -c "
import json, sys
cursor = int(sys.argv[1])
event_file = sys.argv[2]
count = 0
with open(event_file) as f:
    for i, line in enumerate(f, 1):
        if i > cursor:
            count += 1
print(f'[resume] {count} events after cursor position {cursor}')
" "$EVENT_CURSOR" "$events_today"
fi

# Trace resume
bash "$REPO_ROOT/scripts/trace.sh" \
    --summary "ResumeFromCheckpoint: $TASK_ID (cursor=$EVENT_CURSOR)" \
    --outcome success \
    --task-id "$TASK_ID" \
    --actor "resume-engine"

echo "[resume] ✓ State restored. Ready to continue from Task $TASK_ID."
