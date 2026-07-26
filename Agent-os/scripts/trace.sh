#!/usr/bin/env bash
set -euo pipefail

# Resolve to repo root (Agent-os/) regardless of where script is called from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# trace.sh — append a JSONL event to events/YYYY-MM-DD.jsonl
# Usage: trace.sh --summary "..." --outcome success|failure --task-id T-... --story-id US-... --actor orchestrator

summary=""
outcome=""
task_id=""
story_id=""
actor=""
run_id=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --summary)  summary="$2";  shift 2 ;;
        --outcome)  outcome="$2";  shift 2 ;;
        --task-id)  task_id="$2";  shift 2 ;;
        --story-id) story_id="$2"; shift 2 ;;
        --actor)    actor="$2";    shift 2 ;;
        --run-id)   run_id="$2";   shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# Defaults
actor="${actor:-orchestrator}"
outcome="${outcome:-unknown}"

ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
today=$(date -u +"%Y-%m-%d")

events_dir="events"
events_file="${events_dir}/${today}.jsonl"

mkdir -p "$events_dir"

# Auto-generate run_id if not provided
if [[ -z "$run_id" ]]; then
    nnn=1
    if [[ -f "$events_file" ]]; then
        # Find highest NNN in today's run_ids using Python (jq not available)
        last_nnn=$(python -c "
import re, sys
max_n = 0
try:
    with open('$events_file') as f:
        for line in f:
            m = re.search(r'R-\\d{4}-\\d{2}-\\d{2}-(\\d{3})', line)
            if m:
                n = int(m.group(1))
                if n > max_n:
                    max_n = n
except FileNotFoundError:
    pass
print(max_n)
")
        if [[ "$last_nnn" =~ ^[0-9]+$ ]] && [[ "$last_nnn" -gt 0 ]]; then
            nnn=$((last_nnn + 1))
        fi
    fi
    run_id=$(printf "R-%s-%03d" "$today" "$nnn")
fi

# Build and validate JSON using Python (pass args via sys.argv to avoid quoting issues)
payload=$(python -c "
import json, sys
obj = {
    'schema_version': 1,
    'ts': sys.argv[1],
    'run_id': sys.argv[2],
    'task_id': sys.argv[3] if sys.argv[3] else None,
    'story_id': sys.argv[4] if sys.argv[4] else None,
    'actor': sys.argv[5],
    'event': 'Trace',
    'summary': sys.argv[6],
    'outcome': sys.argv[7],
    'tokens': None,
    'cost_usd': None,
    'duration_ms': None
}
# Remove None values
obj = {k: v for k, v in obj.items() if v is not None}
print(json.dumps(obj, separators=(',', ':')))
" "$ts" "$run_id" "$task_id" "$story_id" "$actor" "$summary" "$outcome")

# Validate JSON
python -c "import json, sys; json.loads(sys.argv[1])" "$payload" || { echo "Invalid JSON" >&2; exit 1; }

echo "$payload" >> "$events_file"
exit 0
