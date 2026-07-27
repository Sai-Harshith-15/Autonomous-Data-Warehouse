#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# dispatch.sh v2 — Route coding tasks via OmniRoute (multi-provider proxy)
# =============================================================================
# M1: AI Software Factory — OmniRoute as sole agent dispatch layer
#
# Architecture:
#   curl → OmniRoute (localhost:20128/api/v1/chat/completions)
#        → auto/coding:pro (primary) / auto/coding:fast (fallback)
#
# Usage:
#   scripts/dispatch.sh --plan <plan.md> --task-id <T-...> \
#       [--model <auto/coding:pro>] [--dir <workdir>]
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CALLER_DIR="$(pwd)"
cd "$REPO_ROOT"

OMNIROUTE_URL="${OMNIROUTE_URL:-http://localhost:20128/api/v1/chat/completions}"
TIMEOUT_SECONDS="${DISPATCH_TIMEOUT:-300}"

plan_file=""
task_id=""
model="auto/coding:pro"
workdir=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --plan)     plan_file="$2";  shift 2 ;;
        --task-id)  task_id="$2";    shift 2 ;;
        --model)    model="$2";      shift 2 ;;
        --dir)      workdir="$2";    shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$plan_file" || -z "$task_id" ]]; then
    echo "Usage: dispatch.sh --plan <plan.md> --task-id <T-...> [--model auto/coding:pro]" >&2
    exit 1
fi

# Default workdir to repo root
workdir="${workdir:-$REPO_ROOT}"

# Resolve plan file path
if [[ "$plan_file" != /* ]]; then
    plan_file="${CALLER_DIR}/${plan_file}"
fi

# Extract plan metadata using common helper
_strip_quotes() { sed -E 's/^["'"'"']|["'"'"']$//g' <<<"$1"; }

plan_file_win=$(cygpath -w "$plan_file" 2>/dev/null || echo "$plan_file")
story_id=$(python -c "
import sys,re
with open(sys.argv[1]) as f: content=f.read()
m=re.search(r'^---\\s*\\n(.*?)\\n---', content, re.DOTALL)
if m:
    m2=re.search(r'plan_id:\\s*(\\S+)', m.group(1))
    if m2: print(m2.group(1).strip())
" "$plan_file_win")
story_id="${story_id:-$task_id}"

# Build system + user prompt from plan file
echo "[dispatch] Reading plan: $plan_file"

prompt=$(python -c "
import sys, re
with open(sys.argv[1], encoding='utf-8') as f:
    content = f.read()
content = re.sub(r'^---\\s*\\n.*?\\n---\\s*\\n', '', content, count=1, flags=re.DOTALL)
parts = []
for section in ['# Goal', '## Stories', '## Context', '## Constraints']:
    m = re.search(rf'^{section}\\s*\\n(.*?)(?=\\n##?\\s|\\Z)', content, re.DOTALL|re.MULTILINE)
    if m:
        parts.append(m.group(0).strip())
print('\\n\\n'.join(parts)[:6000])
" "$plan_file_win")

echo "[dispatch] Model:  $model"
echo "[dispatch] Story:  $story_id"
echo "[dispatch] Task:   $task_id"
echo "[dispatch] Prompt: ${#prompt} chars"

# Artifact directory
artifact_dir="artifacts/${task_id}"
mkdir -p "$artifact_dir"

# --- Call OmniRoute via curl ---
echo "[dispatch] Invoking OmniRoute → $model ..."

# Build JSON payload (Python avoids quoting hell)
payload_file="${artifact_dir}/request.json"
python -c "
import json, sys

system_msg = '''You are an expert software engineer coding agent. 
Your task is to produce production-quality code. 

IMPORTANT RULES:
1. Write COMPLETE, WORKING code — no stubs, no TODOs
2. Output code directly in your response, using proper formatting
3. Include ALL necessary imports, type hints, and error handling
4. Do NOT write markdown fences (no \`\`\`python blocks) — just plain code
5. Write files to the paths specified in the task
6. If you need to create directories, include mkdir commands
7. Every file must be complete and runnable
8. Prefer using Python for file operations (open/write, os.makedirs)'''

payload = {
    'model': sys.argv[1],
    'messages': [
        {'role': 'system', 'content': system_msg},
        {'role': 'user', 'content': sys.argv[2]}
    ],
    'stream': False,
    'max_tokens': 8000,
    'temperature': 0
}
print(json.dumps(payload))
" "$model" "$prompt" > "$payload_file"

# Execute curl with timeout
response_file="${artifact_dir}/response.json"
stderr_file="${artifact_dir}/stderr.txt"
set +e
curl -s -X POST "$OMNIROUTE_URL" \
    -H "Content-Type: application/json" \
    -d "@$payload_file" \
    --max-time "$TIMEOUT_SECONDS" \
    -o "$response_file" 2>"$stderr_file"
curl_exit=$?
set -e

echo "[dispatch] curl exit: $curl_exit"

# --- Parse response ---
if [[ $curl_exit -ne 0 ]] || [[ ! -s "$response_file" ]]; then
    error_msg=$(cat "$stderr_file" 2>/dev/null || echo "curl exit $curl_exit, empty response")
    echo "[dispatch] ERROR: $error_msg"
    outcome="failure"
    error_class="TRANSIENT"
else
    # Extract content from OpenAI-style response
    content=$(python -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
choice = data.get('choices', [{}])[0]
msg = choice.get('message', {})
print(msg.get('content', ''))
" "$response_file" 2>/dev/null || echo "")

    model_used=$(python -c "import json; d=json.load(open('$response_file')); print(d.get('model','unknown'))" 2>/dev/null || echo "unknown")
    tokens=$(python -c "import json; d=json.load(open('$response_file')); u=d.get('usage',{}); print(u.get('total_tokens',0))" 2>/dev/null || echo "0")

    echo "[dispatch] Model used: $model_used"
    echo "[dispatch] Tokens:     $tokens"
    echo "[dispatch] Content:    ${#content} chars"

    if [[ -z "$content" ]]; then
        echo "[dispatch] ERROR: Empty model response"
        outcome="failure"
        error_class="EMPTY_OUTPUT"
    else
        # Save raw agent output
        echo "$content" > "${artifact_dir}/agent-output.md"

        # Extract files from agent output (Python code blocks or direct file writes)
        # Write content to files using Python
        python -c "
import os, re, sys

content = open(sys.argv[1]).read()
artifact_dir = sys.argv[2]
workdir = sys.argv[3]

# Strategy 1: Look for file write commands in the code
# Pattern: with open('path', 'w') or os.makedirs + open
# We just save the full response for now — the verify.sh will handle execution

# Save a summary
summary = f'''Agent: {sys.argv[4]}
Model: {sys.argv[5]}
Tokens: {sys.argv[6]}
Response length: {len(content)} chars

Full response saved to {artifact_dir}/agent-output.md
'''
with open(f'{artifact_dir}/agent-summary.txt', 'w') as f:
    f.write(summary)
" "${artifact_dir}/agent-output.md" "$artifact_dir" "$workdir" "$task_id" "$model_used" "$tokens"

        outcome="success"
        error_class=""
    fi
fi

# --- Save dispatch summary ---
python -c "
import json, sys
from datetime import datetime, timezone
summary = {
    'schema_version': 1,
    'task_id': sys.argv[1],
    'story_id': sys.argv[2],
    'model_requested': sys.argv[3],
    'model_used': sys.argv[4],
    'outcome': sys.argv[5],
    'error_class': sys.argv[6] if len(sys.argv) > 6 and sys.argv[6] else None,
    'timestamp': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
}
with open(sys.argv[7], 'w') as f:
    json.dump(summary, f, indent=2)
" "$task_id" "$story_id" "$model" "${model_used:-unknown}" "$outcome" "$error_class" "${artifact_dir}/dispatch-summary.json"

# --- Trace ---
bash "$REPO_ROOT/scripts/trace.sh" \
    --summary "TaskDispatched: $task_id via OmniRoute → $model" \
    --outcome "$outcome" \
    --task-id "$task_id" \
    --story-id "$story_id" \
    --actor "dispatcher"

# --- Exit ---
if [[ "$outcome" == "success" ]]; then
    echo "[dispatch] ✓ Task $task_id completed successfully"
    echo "[dispatch]   Agent output: ${artifact_dir}/agent-output.md"
    exit 0
else
    echo "[dispatch] ✗ Task $task_id failed: $error_class" >&2
    exit 1
fi
