#!/usr/bin/env bash
set -euo pipefail

# dag.sh — build dependency graph from task list
# Usage: dag.sh --plan <plan.md> [--json]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

plan_file=""
output_json=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --plan) plan_file="$2"; shift 2 ;;
        --json) output_json=true; shift ;;
        *) echo "Unknown: $1" >&2; exit 1 ;;
    esac
done

[[ -z "$plan_file" ]] && { echo "Usage: dag.sh --plan <plan.md> [--json]" >&2; exit 1; }

# Build DAG using Python
plan_win=$(cygpath -w "$plan_file" 2>/dev/null || echo "$plan_file")

python -c "
import json, re, sys

with open(sys.argv[1], encoding='utf-8') as f:
    content = f.read()

# Parse YAML frontmatter for plan metadata
fm = {}
m = re.search(r'^---\s*\n(.*?)\n---\s*\n', content, re.DOTALL)
if m:
    for line in m.group(1).strip().split('\n'):
        if ':' in line:
            k, v = line.split(':', 1)
            fm[k.strip()] = v.strip().strip('\"').strip(\"'\")

# Parse body for task sections
body = re.sub(r'^---\s*\n.*?\n---\s*\n', '', content, count=1, flags=re.DOTALL)

# Find tasks from ## Stories or ## Tasks section
tasks = []
for section_name in ['## Stories', '## Tasks']:
    m = re.search(rf'^{section_name}\s*\n(.*?)(?=\n##|\Z)', body, re.DOTALL)
    if m:
        section = m.group(1)
        for line in section.strip().split('\n'):
            line = line.strip()
            if line.startswith('- [ ]') or line.startswith('- [x]'):
                task = line[5:].strip()
                tasks.append({'name': task, 'status': 'pending'})

# Build DAG: sequence pattern for M2
# Requirements → Architecture → [Backend ∥ Frontend ∥ QA] → Integration → Release
plan_id = fm.get('plan_id', 'TASK')

dag = {
    'plan_id': plan_id,
    'nodes': [
        {'id': 'T01', 'name': 'requirements', 'depends_on': [], 'agent': 'requirements-analyst', 'outputs': ['docs/stories/'], 'parallel_group': None},
        {'id': 'T02', 'name': 'architecture', 'depends_on': ['T01'], 'agent': 'software-architect', 'outputs': ['docs/decisions/'], 'parallel_group': None},
        {'id': 'T03', 'name': 'backend', 'depends_on': ['T02'], 'agent': 'sdlc-backend-engineer', 'outputs': ['projects/<app>/backend/'], 'parallel_group': 'impl'},
        {'id': 'T04', 'name': 'frontend', 'depends_on': ['T02'], 'agent': 'sdlc-frontend-engineer', 'outputs': ['projects/<app>/frontend/'], 'parallel_group': 'impl'},
        {'id': 'T05', 'name': 'qa', 'depends_on': ['T02'], 'agent': 'sdlc-qa-engineer', 'outputs': ['projects/<app>/qa/'], 'parallel_group': 'impl'},
        {'id': 'T06', 'name': 'integration', 'depends_on': ['T03', 'T04', 'T05'], 'agent': 'sdlc-integration-engineer', 'outputs': ['projects/<app>/'], 'parallel_group': None},
        {'id': 'T07', 'name': 'release', 'depends_on': ['T06'], 'agent': 'sdlc-release-manager', 'outputs': ['main'], 'parallel_group': None},
    ],
    'parallel_groups': {
        'impl': {'max_concurrent': 3, 'nodes': ['T03', 'T04', 'T05']}
    }
}

print(json.dumps(dag, indent=2))
" "$plan_win"
