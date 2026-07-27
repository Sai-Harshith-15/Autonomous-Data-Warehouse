#!/usr/bin/env bash
set -euo pipefail

# integration.sh — merge parallel agent outputs, verify no overlap
# Usage: integration.sh --dag <dag.json> --project <projects/app/>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

dag_file=""
project_dir=""
verify_only=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dag) dag_file="$2"; shift 2 ;;
        --project) project_dir="$2"; shift 2 ;;
        --verify-only) verify_only=true; shift ;;
        *) echo "Unknown: $1" >&2; exit 1 ;;
    esac
done

[[ -z "$project_dir" ]] && { echo "Usage: integration.sh --dag <dag.json> --project <path> [--verify-only]" >&2; exit 1; }

# Get outputs from all agents in parallel groups
verify_overlap() {
    local dir="$1"
    echo "[integration] Checking output isolation in $dir..."
    
    # Find all files written by agents
    python -c "
import os, json, sys
from collections import defaultdict

project = sys.argv[1]

# Collect files per agent group
agent_files = defaultdict(list)
if os.path.exists(project):
    for root, dirs, files in os.walk(project):
        for f in files:
            rel = os.path.relpath(os.path.join(root, f), project)
            # Determine agent from path prefix
            parts = rel.replace('\\\\', '/').split('/')
            if len(parts) > 1:
                agent = parts[0]  # backend/, frontend/, qa/
                agent_files[agent].append(rel)

# Check for overlaps
overlaps = []
all_files = []
for agent, files in agent_files.items():
    all_files.extend(files)

# Any file appearing in multiple agent dirs?
from collections import Counter
basenames = Counter()
path_map = {}
for f in all_files:
    bn = os.path.basename(f)
    basenames[bn] += 1
    if bn not in path_map:
        path_map[bn] = []
    path_map[bn].append(f)

for bn, count in basenames.items():
    if count > 1:
        overlaps.append({'file': bn, 'paths': path_map[bn]})

result = {
    'total_files': len(all_files),
    'agent_dirs': list(agent_files.keys()),
    'overlaps': overlaps,
    'clean': len(overlaps) == 0
}
print(json.dumps(result, indent=2))
if not result['clean']:
    print(f'OVERLAP DETECTED: {len(overlaps)} files written by multiple agents', file=sys.stderr)
    sys.exit(1)
" "$dir"
    return $?
}

# Run verification
verify_overlap "$project_dir"
overlap_exit=$?

if $verify_only; then
    if [[ $overlap_exit -eq 0 ]]; then
        echo "[integration] ✓ Output isolation verified — no overlaps"
        exit 0
    else
        echo "[integration] ✗ Output overlap detected" >&2
        exit 1
    fi
fi

# Merge step: copy all agent outputs to a unified directory
merged_dir="${project_dir}/merged"
rm -rf "$merged_dir" 2>/dev/null || true
mkdir -p "$merged_dir"

echo "[integration] Merging agent outputs to $merged_dir..."
for agent_dir in "$project_dir"/backend "$project_dir"/frontend "$project_dir"/qa; do
    [[ -d "$agent_dir" ]] || continue
    cp -r "$agent_dir"/* "$merged_dir/" 2>/dev/null || true
done

echo "[integration] ✓ Merge complete — $(find "$merged_dir" -type f | wc -l) files"
echo "[integration] ✓ Output isolation: $( [[ $overlap_exit -eq 0 ]] && echo 'PASSED' || echo 'FAILED' )"

# Trace
bash "$REPO_ROOT/scripts/trace.sh" \
    --summary "IntegrationComplete: $project_dir (isolated=$([[ $overlap_exit -eq 0 ]] && echo true || echo false))" \
    --outcome "$([[ $overlap_exit -eq 0 ]] && echo success || echo failure)" \
    --actor "integration-engineer"

exit $overlap_exit
