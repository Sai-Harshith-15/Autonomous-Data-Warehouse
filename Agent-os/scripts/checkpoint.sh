#!/usr/bin/env bash
set -euo pipefail

# checkpoint.sh — save factory state for resume (M5)
# Usage: checkpoint.sh --run-id <R-...> --task-id <T-...> [--completed <node1,node2>]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

run_id=""
task_id=""
completed_nodes=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run-id) run_id="$2"; shift 2 ;;
        --task-id) task_id="$2"; shift 2 ;;
        --completed) completed_nodes="$2"; shift 2 ;;
        *) shift ;;
    esac
done
[[ -z "$run_id" || -z "$task_id" ]] && { echo "Usage: checkpoint.sh --run-id <R-...> --task-id <T-...>" >&2; exit 1; }

ckpt_dir="checkpoints/${run_id}"
mkdir -p "$ckpt_dir"
ckpt_file="${ckpt_dir}/${task_id}.json"

# Build checkpoint via Python
python -c "
import json, os, hashlib, sys
from datetime import datetime, timezone

run_id = sys.argv[1]
task_id = sys.argv[2]
completed = sys.argv[3].split(',') if sys.argv[3] else []

# Event cursor — count lines in today's event log
events_file = 'events/' + datetime.now(timezone.utc).strftime('%Y-%m-%d') + '.jsonl'
cursor = 0
if os.path.exists(events_file):
    with open(events_file) as f:
        cursor = sum(1 for _ in f)

# Git SHA
import subprocess
git_sha = subprocess.run(['git','rev-parse','HEAD'], capture_output=True, text=True).stdout.strip()

# Artifact hashes
artifacts_dir = f'artifacts/{task_id}'
artifact_hashes = {}
if os.path.isdir(artifacts_dir):
    for root, dirs, files in os.walk(artifacts_dir):
        for fn in files:
            fp = os.path.join(root, fn)
            try:
                h = hashlib.sha256()
                with open(fp, 'rb') as f:
                    while chunk := f.read(8192):
                        h.update(chunk)
                rel = os.path.relpath(fp, 'artifacts')
                artifact_hashes[rel] = h.hexdigest()[:16]
            except:
                pass

ckpt = {
    'schema_version': 1,
    'run_id': run_id,
    'task_id': task_id,
    'completed_nodes': completed,
    'event_cursor': cursor,
    'git_sha': git_sha,
    'artifact_hashes': artifact_hashes,
    'budget_spent': {'tokens': 0, 'cost_usd': 0},
    'timestamp': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
}

with open(sys.argv[4], 'w') as f:
    json.dump(ckpt, f, indent=2)
print(json.dumps(ckpt, indent=2))
" "$run_id" "$task_id" "$completed_nodes" "$ckpt_file"

# Trace
bash "$REPO_ROOT/scripts/trace.sh" \
    --summary "CheckpointSaved: $task_id (cursor=$(python -c "import json; print(json.load(open('$ckpt_file'))['event_cursor'])"))" \
    --outcome success \
    --task-id "$task_id" \
    --actor "checkpoint-engine"

echo "[checkpoint] ✓ Saved to $ckpt_file"
