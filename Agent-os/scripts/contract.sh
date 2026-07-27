#!/usr/bin/env bash
set -euo pipefail

# contract.sh — generate typed JSON contract from plan file
# Usage: contract.sh --plan <plan.md> --task-id <T-...> [--owner <agent-name>]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CALLER_DIR="$(pwd)"
cd "$REPO_ROOT"

plan_file=""
task_id=""
owner_agent=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --plan)  plan_file="$2";  shift 2 ;;
        --task-id) task_id="$2";  shift 2 ;;
        --owner) owner_agent="$2"; shift 2 ;;
        *) echo "Unknown: $1" >&2; exit 1 ;;
    esac
done

[[ -z "$plan_file" || -z "$task_id" ]] && { echo "Usage: contract.sh --plan <plan.md> --task-id <T-...> [--owner <agent>]" >&2; exit 1; }

[[ "$plan_file" != /* ]] && plan_file="${CALLER_DIR}/${plan_file}"
plan_win=$(cygpath -w "$plan_file" 2>/dev/null || echo "$plan_file")

# Generate contract using Python
artifact_dir="artifacts/${task_id}"
mkdir -p "$artifact_dir"
contract_file="${artifact_dir}/contract.json"

python -c "
import json, re, sys, os
from datetime import datetime, timezone

plan = sys.argv[1]
task_id = sys.argv[2]
owner = sys.argv[3] if sys.argv[3] else None
out_path = sys.argv[4]

with open(plan, encoding='utf-8') as f:
    content = f.read()

# Parse YAML frontmatter
fm = {}
m = re.search(r'^---\s*\n(.*?)\n---\s*\n', content, re.DOTALL)
if m:
    for line in m.group(1).strip().split('\n'):
        line = line.strip()
        if ':' in line:
            k, v = line.split(':', 1)
            v = v.strip().strip('\"').strip(\"'\")
            if v.startswith('[') and v.endswith(']'):
                v = [x.strip().strip('\"').strip(\"'\") for x in v[1:-1].split(',') if x.strip()]
            elif v.startswith('-'):
                pass  # list items handled below
            fm[k.strip()] = v

# Parse body
body = re.sub(r'^---\s*\n.*?\n---\s*\n', '', content, count=1, flags=re.DOTALL)

# Extract goal
goal = ''
gm = re.search(r'^#\s*Goal\s*\n(.*?)(?=\n#|\Z)', body, re.DOTALL)
if gm:
    goal = gm.group(1).strip()

# Extract acceptance criteria from YAML
acceptance = fm.get('acceptance', [])
if isinstance(acceptance, str):
    acceptance = [acceptance] if acceptance else []

# Build inputs from plan references
inputs = [fm.get('plan_id', task_id) + '-plan']

# Build outputs from plan
outputs = fm.get('outputs', [f'projects/{fm.get(\"plan_id\", task_id)}/**'])
if isinstance(outputs, str):
    outputs = [outputs] if outputs else []

# Build constraints
constraints = fm.get('constraints', [])
if isinstance(constraints, str):
    constraints = [constraints] if constraints else []

# Sandbox tier
sandbox_map = {
    'sdlc-backend-engineer': 'T1',
    'sdlc-frontend-engineer': 'T1',
    'sdlc-qa-engineer': 'T1',
    'sdlc-integration-engineer': 'T1',
    'sdlc-security-reviewer': 'T0',
    'sdlc-requirements-analyst': 'T0',
    'sdlc-software-architect': 'T0',
}
sandbox_tier = sandbox_map.get(owner or fm.get('owner_agent', ''), 'T1')

contract = {
    'schema_version': 1,
    'task_id': task_id,
    'story_id': fm.get('plan_id', task_id),
    'goal': goal,
    'inputs': inputs,
    'outputs': outputs,
    'constraints': constraints,
    'owner_agent': owner or fm.get('owner_agent', 'sdlc-backend-engineer'),
    'model': fm.get('model', 'opencode-go/deepseek-v4-pro'),
    'sandbox_tier': sandbox_tier,
    'acceptance': acceptance,
    'depends_on': fm.get('depends_on', []),
    'created': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'idempotency_key': f'{task_id}-v1'
}

with open(out_path, 'w') as f:
    json.dump(contract, f, indent=2)

print(json.dumps(contract, indent=2))
" "$plan_win" "$task_id" "${owner_agent}" "$contract_file"

# Trace
bash "$REPO_ROOT/scripts/trace.sh" \
    --summary "ContractCreated: $task_id" \
    --outcome success \
    --task-id "$task_id" \
    --story-id "$(python -c "import json; print(json.load(open('$contract_file'))['story_id'])")" \
    --actor "contract-generator"

echo "[contract] ✓ Contract written to $contract_file"
