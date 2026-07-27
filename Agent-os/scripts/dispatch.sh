#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# dispatch.sh — Route a coding task to DeepSeek V4 Pro via OpenCode Go CLI
# =============================================================================
# M1: AI Software Factory — The Smallest Working Factory
#
# Usage:
#   scripts/dispatch.sh --plan <plan.md> --task-id <T-...> \
#       [--model <model-id>] [--dir <workdir>]
#
# Reads a plan file (YAML frontmatter + markdown), extracts the goal and
# stories, resolves the model, invokes the OpenCode Go CLI, captures output,
# and records the result via trace.sh.
# =============================================================================

# --- Resolve paths (cwd-independent) -----------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CALLER_DIR="$(pwd)"

# We change to REPO_ROOT so all repo-relative paths resolve correctly.
cd "$REPO_ROOT"

# --- Argument parsing --------------------------------------------------------
plan_file=""
task_id=""
model=""
workdir=""
show_help=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --plan)     plan_file="$2";  shift 2 ;;
        --task-id)  task_id="$2";    shift 2 ;;
        --model)    model="$2";      shift 2 ;;
        --dir)      workdir="$2";    shift 2 ;;
        --help|-h)  show_help=true;  shift   ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

if $show_help; then
    echo "Usage: scripts/dispatch.sh --plan <plan.md> --task-id <T-...> [--model <model-id>] [--dir <workdir>]"
    echo ""
    echo "Arguments:"
    echo "  --plan <path>     Path to the plan file (YAML frontmatter + markdown)"
    echo "  --task-id <T-..>  Task identifier (e.g. T-0000001)"
    echo "  --model <id>      Override the model (default: from tool-registry.yaml or deepseek-v4-pro)"
    echo "  --dir <workdir>   Working directory for the agent (default: REPO_ROOT)"
    echo "  --help, -h        Show this message"
    exit 0
fi

# --- Validation --------------------------------------------------------------
if [[ -z "$plan_file" ]]; then
    echo "ERROR: --plan is required" >&2
    exit 2
fi
if [[ -z "$task_id" ]]; then
    echo "ERROR: --task-id is required" >&2
    exit 2
fi

# Resolve plan_file: absolute paths stay as-is, relative paths resolved from caller's dir
if [[ "$plan_file" != /* ]]; then
    plan_file="${CALLER_DIR}/${plan_file}"
fi

if [[ ! -f "$plan_file" ]]; then
    echo "ERROR: Plan file not found: $plan_file" >&2
    exit 2
fi

# Default workdir to REPO_ROOT
workdir="${workdir:-$REPO_ROOT}"

echo "[dispatch] Plan:   $plan_file"
echo "[dispatch] Task:   $task_id"
echo "[dispatch] Workdir: $workdir"

# --- Helper: convert MSYS path to Windows for Python -------------------------
to_win() {
    local p="$1"
    cygpath -w "$p" 2>/dev/null || echo "$p"
}

# --- Parse plan frontmatter --------------------------------------------------
plan_win=$(to_win "$plan_file")

# Extract YAML frontmatter fields using Python (consistent with trace.sh/verify.sh)
frontmatter_json=$(python -c "
import sys, re, json

plan_path = sys.argv[1]
try:
    with open(plan_path, encoding='utf-8') as f:
        content = f.read()
except FileNotFoundError:
    json.dump({'error': 'file not found'}, sys.stdout)
    sys.exit(1)

# Extract frontmatter between first --- and ---
m = re.match(r'^---\s*\n(.*?)\n---\s*\n', content, re.DOTALL)
if not m:
    json.dump({'error': 'no frontmatter'}, sys.stdout)
    sys.exit(0)

raw = m.group(1)
data = {}

# Extract simple scalar YAML fields (key: value)
for key in ['plan_id', 'title', 'status', 'lane', 'model', 'owner_agent', 'verify_cmd', 'schema_version']:
    m2 = re.search(rf'^{key}:\s*(.*?)\s*$', raw, re.MULTILINE)
    if m2:
        val = m2.group(1).strip()
        # Strip surrounding quotes
        if (val.startswith('\"') and val.endswith('\"')) or (val.startswith(\"'\") and val.endswith(\"'\")):
            val = val[1:-1]
        data[key] = val

json.dump(data, sys.stdout)
" "$plan_win")

# Extract story_id from frontmatter (plan_id is the story ID, e.g. US-0001)
story_id=$(python -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('plan_id',''))" "$frontmatter_json")

# Extract goal text (first # Goal section after frontmatter)
goal_text=$(python -c "
import sys, re

plan_path = sys.argv[1]
with open(plan_path, encoding='utf-8') as f:
    content = f.read()

# Strip frontmatter
content = re.sub(r'^---\s*\n.*?\n---\s*\n', '', content, count=1, flags=re.DOTALL)

# Extract everything from '# Goal' to the next '##' or end of file
m = re.search(r'^#[ ]*Goal\s*\n(.*?)(?=\n#[#]|\Z)', content, re.DOTALL | re.MULTILINE)
if m:
    goal = m.group(1).strip()
    print(goal)
else:
    # Fallback: extract first # heading
    m2 = re.search(r'^#[ ]+([^\n]+)', content, re.MULTILINE)
    if m2:
        print(m2.group(1).strip())
" "$plan_win")

echo "[dispatch] Story:  $story_id"
echo "[dispatch] Goal:   ${goal_text:0:120}..."

# --- Resolve model -----------------------------------------------------------
# Priority: 1) --model flag  2) plan frontmatter  3) tool-registry.yaml routing
if [[ -z "$model" ]]; then
    # Try plan frontmatter first
    model_from_plan=$(python -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('model',''))" "$frontmatter_json")
    if [[ -n "$model_from_plan" ]]; then
        # Strip provider prefix if present (e.g. opencode-go/deepseek-v4-pro → deepseek-v4-pro)
        model="${model_from_plan#*/}"
    fi
fi

if [[ -z "$model" ]]; then
    # Read from tool-registry.yaml
    lane=$(python -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('lane','tiny'))" "$frontmatter_json")
    registry_win=$(to_win "$REPO_ROOT/docs/tool-registry.yaml")
    model=$(python -c "
import sys, re

registry_path = sys.argv[1]
lane = sys.argv[2]

try:
    with open(registry_path, encoding='utf-8') as f:
        content = f.read()
except FileNotFoundError:
    # Fallback if registry is missing
    print('deepseek-v4-pro')
    sys.exit(0)

# Try routing.<lane>.coding
m = re.search(rf'^\s*{re.escape(lane)}:\s*\n(.*?)(?=\n\S|\Z)', content, re.DOTALL | re.MULTILINE)
if m:
    block = m.group(1)
    m2 = re.search(r'coding:\s*(\S+)', block)
    if m2:
        val = m2.group(1).strip().split('/')[-1]  # strip provider prefix
        print(val)
        sys.exit(0)

# Fallback: default coding model
print('deepseek-v4-pro')
" "$registry_win" "$lane")
fi

# Ensure model string has correct prefix for opencode CLI
# opencode-go/<model> — strip any existing prefix just in case
model_base="${model##*/}"  # strip provider prefix if already present
model_for_cli="opencode-go/${model_base}"

echo "[dispatch] Model:  $model_for_cli"

# --- Build task description --------------------------------------------------
# Concatenate goal + stories into a clear prompt for the agent
task_description=$(python -c "
import sys, re

plan_path = sys.argv[1]
with open(plan_path, encoding='utf-8') as f:
    content = f.read()

# Strip frontmatter
content = re.sub(r'^---\s*\n.*?\n---\s*\n', '', content, count=1, flags=re.DOTALL)

# Extract goal section
goal_block = ''
m = re.search(r'^#[ ]*Goal\s*\n(.*?)(?=\n#[#]|\Z)', content, re.DOTALL | re.MULTILINE)
if m:
    goal_block = m.group(0).strip()

# Extract stories section
stories_block = ''
m = re.search(r'^##[ ]*Stories?\s*\n(.*?)(?=\n##|\Z)', content, re.DOTALL | re.MULTILINE)
if m:
    stories_block = m.group(0).strip()

# Extract constraints section
constraints_block = ''
m = re.search(r'^##[ ]*Constraints?\s*\n(.*?)(?=\n##|\Z)', content, re.DOTALL | re.MULTILINE)
if m:
    constraints_block = m.group(0).strip()

# Assemble prompt
parts = []
if goal_block:
    parts.append(goal_block)
if stories_block:
    parts.append(stories_block)
if constraints_block:
    parts.append(constraints_block)

# If nothing found, use a reasonable default
if not parts:
    parts.append(content.strip()[:2000])

prompt = '\n\n'.join(parts)
print(prompt[:4000])  # Cap prompt length
" "$plan_win")

echo "[dispatch] Task description ready (${#task_description} chars)"

# --- Prepare artifact directory ----------------------------------------------
artifact_dir="artifacts/${task_id}"
mkdir -p "$artifact_dir"

jsonl_output="${artifact_dir}/agent-output.jsonl"
md_output="${artifact_dir}/agent-output.md"

# --- Helper: classify error from stderr --------------------------------------
classify_error() {
    local stderr_text="$1"
    local model_used="$2"
    local exit_code="$3"

    if echo "$stderr_text" | grep -qi "command not found\|No such file\|opencode.*not recognized"; then
        echo "ENVIRONMENT|opencode CLI not found or not installed"
    elif echo "$stderr_text" | grep -qi "timed out\|timeout\|context deadline exceeded\|deadline_exceeded"; then
        echo "TRANSIENT|opencode invocation timed out (${TIMEOUT_SECONDS}s limit)"
    elif echo "$stderr_text" | grep -qi "model.*not.*found\|model.*unavailable\|no such model\|unknown model\|invalid.*model"; then
        echo "MODEL_UNAVAILABLE|Model $model_used is not available"
    else
        echo "AGENT_FAILURE|opencode exited with code $exit_code"
    fi
}

# --- Helper: run opencode with a given model, format, and stderr path ---------
run_opencode() {
    local model_cli="$1"
    local format="$2"
    local output_file="$3"
    local stderr_file="$4"
    local rc

    echo "[dispatch] Invoking: opencode run -m $model_cli --auto --dir $workdir --format $format -f <plan>" >&2

    set +e
    opencode run \
        -m "$model_cli" \
        --auto \
        --dir "$workdir" \
        --format "$format" \
        -f "$plan_abs" \
        "$task_description" \
        > "$output_file" 2>"$stderr_file"
    rc=$?
    set -e
    echo $rc
}

# --- Prepare plan absolute path and task file ---------------------------------
task_file="${artifact_dir}/task-prompt.txt"
echo "$task_description" > "$task_file"

plan_abs=$(cd "$(dirname "$plan_file")" && pwd)/$(basename "$plan_file")
plan_abs="${plan_abs//\\//}"  # ensure forward slashes

TIMEOUT_SECONDS=600
exit_code=0
error_class=""
error_detail=""
fallback_used=false
model_used="$model_for_cli"

# --- Invoke OpenCode Go CLI (primary model, JSON format) ----------------------
echo "[dispatch] Invoking opencode CLI (primary: $model_for_cli)..."
echo "[dispatch] Command: opencode run -m $model_for_cli --auto --dir $workdir -f <plan> \"<task>\""

set +e
jsonl_exit=$(run_opencode "$model_for_cli" "json" "$jsonl_output" "${artifact_dir}/stderr-json.txt")
set -e

# --- Fallback: if MODEL_UNAVAILABLE, retry with deepseek-v4-flash -------------
if [[ $jsonl_exit -ne 0 ]]; then
    stderr_json=$(cat "${artifact_dir}/stderr-json.txt" 2>/dev/null || true)
    error_info=$(classify_error "$stderr_json" "$model_for_cli" "$jsonl_exit")
    err_class="${error_info%%|*}"
    err_detail="${error_info#*|}"

    if [[ "$err_class" == "MODEL_UNAVAILABLE" ]]; then
        fallback_model="opencode-go/deepseek-v4-flash"
        echo "[dispatch] Model unavailable, retrying with fallback: $fallback_model"

        set +e
        jsonl_exit=$(run_opencode "$fallback_model" "json" "$jsonl_output" "${artifact_dir}/stderr-json.txt")
        set -e

        if [[ $jsonl_exit -eq 0 ]]; then
            fallback_used=true
            model_used="$fallback_model"
            echo "[dispatch] Fallback model succeeded"
        fi
    else
        # Non-model errors (ENVIRONMENT, TRANSIENT, etc.) — don't retry
        error_class="$err_class"
        error_detail="$err_detail"
    fi
fi

echo "[dispatch] opencode JSON exit: $jsonl_exit"

# --- Second invocation: markdown format for human-readable output -------------
# Run MD format only if JSON invocation succeeded or produced output
md_exit=0
if [[ $jsonl_exit -eq 0 ]] || [[ -s "$jsonl_output" ]]; then
    set +e
    md_exit=$(run_opencode "$model_used" "default" "$md_output" "${artifact_dir}/stderr-md.txt")
    set -e
    exit_code=$md_exit
else
    exit_code=$jsonl_exit
fi

echo "[dispatch] opencode MD exit:   $md_exit"

# --- Error classification (post-fallback) ------------------------------------
if [[ $exit_code -ne 0 ]] && [[ -z "$error_class" ]]; then
    stderr_content=""
    if [[ -f "${artifact_dir}/stderr-json.txt" ]]; then
        stderr_content=$(cat "${artifact_dir}/stderr-json.txt" 2>/dev/null || true)
    fi
    # Also check MD stderr if JSON stderr is empty
    if [[ -z "$stderr_content" ]] && [[ -f "${artifact_dir}/stderr-md.txt" ]]; then
        stderr_content=$(cat "${artifact_dir}/stderr-md.txt" 2>/dev/null || true)
    fi

    error_info=$(classify_error "$stderr_content" "$model_used" "$exit_code")
    error_class="${error_info%%|*}"
    error_detail="${error_info#*|}"
fi

if [[ $exit_code -ne 0 ]]; then
    echo "[dispatch] ERROR CLASS: $error_class — $error_detail" >&2
fi

# --- Post-check: git status --------------------------------------------------
empty_output=false
if [[ -d "$workdir/.git" ]]; then
    git_status=$(git -C "$workdir" status --porcelain 2>/dev/null || true)
    if [[ -z "${git_status// }" ]]; then
        empty_output=true
        echo "[dispatch] WARNING: git workdir is clean — agent may have produced no changes" >&2
        if [[ $exit_code -eq 0 ]]; then
            error_class="EMPTY_OUTPUT"
            error_detail="opencode exited 0 but git status --porcelain is empty"
            exit_code=1
        fi
    else
        echo "[dispatch] Git changes detected:"
        echo "$git_status" | head -5
    fi
else
    echo "[dispatch] No .git directory in workdir — skipping git check"
fi

# --- Determine outcome -------------------------------------------------------
if [[ $exit_code -eq 0 ]]; then
    outcome="success"
else
    outcome="failure"
fi

# --- Write dispatch summary to artifact --------------------------------------
dispatch_summary="${artifact_dir}/dispatch-summary.json"
python -c "
import json, sys, os
from datetime import datetime, timezone

summary = {
    'schema_version': 1,
    'task_id': sys.argv[1],
    'story_id': sys.argv[2],
    'model': sys.argv[3],
    'workdir': sys.argv[4],
    'outcome': sys.argv[5],
    'error_class': sys.argv[6] if sys.argv[6] else None,
    'error_detail': sys.argv[7] if sys.argv[7] else None,
    'fallback_used': sys.argv[9] == 'true',
    'timestamp': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'jsonl_exit': int(sys.argv[8]),
    'git_clean': sys.argv[10] == 'true',
}
with open(sys.argv[11], 'w') as f:
    json.dump(summary, f, indent=2)
" "$task_id" "$story_id" "$model_used" "$workdir" "$outcome" \
  "$error_class" "$error_detail" "$jsonl_exit" "$fallback_used" "$empty_output" "$dispatch_summary"

# --- Call trace.sh -----------------------------------------------------------
echo "[dispatch] Tracing dispatch event..."
trace_args=(--summary "TaskDispatched: $task_id" --outcome "$outcome" --task-id "$task_id" --story-id "$story_id" --actor "dispatcher")
if [[ -n "${run_id:-}" ]]; then
    trace_args+=(--run-id "$run_id")
fi
bash "$REPO_ROOT/scripts/trace.sh" "${trace_args[@]}"

# --- Final exit --------------------------------------------------------------
if [[ $exit_code -eq 0 ]]; then
    echo "[dispatch] ✓ Task $task_id dispatched successfully"
    echo "[dispatch]   JSON output: $jsonl_output"
    echo "[dispatch]   MD output:   $md_output"
    exit 0
else
    echo "[dispatch] ✗ Task $task_id failed: $error_class — $error_detail" >&2
    exit 1
fi
