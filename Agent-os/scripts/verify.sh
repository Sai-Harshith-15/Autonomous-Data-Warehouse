#!/usr/bin/env bash
set -euo pipefail

# Resolve to repo root (Agent-os/) regardless of where script is called from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CALLER_DIR="$(pwd)"
cd "$REPO_ROOT"

# verify.sh — run a story's verify_cmd and record evidence
# Usage: verify.sh --plan <path-to-plan.md> --story-id <US-XXXX> [--run-id <R-...>]

plan_file=""
story_id=""
run_id=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --plan)     plan_file="$2";  shift 2 ;;
        --story-id) story_id="$2"; shift 2 ;;
        --run-id)   run_id="$2";   shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$plan_file" || -z "$story_id" ]]; then
    echo "Usage: verify.sh --plan <plan.md> --story-id <US-XXXX> [--run-id <R-...>]" >&2
    exit 1
fi

# Resolve plan_file: absolute path stays as-is, relative resolved from caller's dir
if [[ "$plan_file" != /* ]]; then
    plan_file="${CALLER_DIR}/${plan_file}"
fi

# Extract verify_cmd from YAML frontmatter using Python
# Convert MSYS path to Windows path for Python compatibility
plan_file_win=$(cygpath -w "$plan_file" 2>/dev/null || echo "$plan_file")
verify_cmd=$(python -c "
import sys, re, subprocess
plan = sys.argv[1]
try:
    with open(plan) as f:
        content = f.read()
except FileNotFoundError:
    sys.exit(1)
m = re.search(r'^---\s*\n(.*?)\n---\s*\n', content, re.DOTALL)
if not m:
    print('', end='')
    sys.exit(0)
frontmatter = m.group(1)
vm = re.search(r'verify_cmd:\s*(.+)', frontmatter)
if vm:
    val = vm.group(1).strip()
    if (val.startswith('\"') and val.endswith('\"')) or (val.startswith(\"'\") and val.endswith(\"'\")):
        val = val[1:-1]
    print(val, end='')
" "$plan_file_win")

if [[ -z "$verify_cmd" ]]; then
    echo "No verify_cmd found in plan frontmatter: $plan_file" >&2
    exit 1
fi

# Create artifact directory
artifact_dir="artifacts/${story_id}"
mkdir -p "$artifact_dir"

output_file="${artifact_dir}/verify-output.txt"
evidence_file="${artifact_dir}/evidence.sha256"

# Run the verify command, capture output
echo "Running verify_cmd: $verify_cmd" > "$output_file"
echo "Plan: $plan_file" >> "$output_file"
echo "Story: $story_id" >> "$output_file"
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> "$output_file"
echo "---" >> "$output_file"

set +e
(eval "$verify_cmd") >> "$output_file" 2>&1
exit_code=$?
set -e

echo "---" >> "$output_file"
echo "Exit code: $exit_code" >> "$output_file"

# Compute evidence hash
sha256sum "$output_file" | awk '{print $1}' > "$evidence_file"

# Determine outcome
if [[ $exit_code -eq 0 ]]; then
    outcome="success"
else
    outcome="failure"
fi

# Trace the event (build args dynamically to avoid empty --task-id)
trace_args=(--summary "GateChecked: $story_id" --outcome "$outcome" --story-id "$story_id" --actor "gate-controller")
[[ -n "$run_id" ]] && trace_args+=(--run-id "$run_id")
bash scripts/trace.sh "${trace_args[@]}"

exit $exit_code
