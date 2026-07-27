#!/usr/bin/env bash
set -euo pipefail

# Resolve to repo root (Agent-os/) regardless of where script is called from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CALLER_DIR="$(pwd)"
cd "$REPO_ROOT"

# feedback-loop.sh — classify failures and route back (re-dispatch or halt)
# Usage: feedback-loop.sh --plan <plan.md> --story-id <US-...> --task-id <T-...> --artifact <verify-output.txt>

plan_file=""
story_id=""
task_id=""
artifact=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --plan)     plan_file="$2";     shift 2 ;;
        --story-id) story_id="$2";      shift 2 ;;
        --task-id)  task_id="$2";       shift 2 ;;
        --artifact) artifact="$2";      shift 2 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$plan_file" || -z "$story_id" || -z "$task_id" || -z "$artifact" ]]; then
    echo "Usage: feedback-loop.sh --plan <plan.md> --story-id <US-...> --task-id <T-...> --artifact <verify-output.txt>" >&2
    exit 1
fi

# Resolve plan_file: absolute path stays as-is, relative resolved from caller's dir
if [[ "$plan_file" != /* ]]; then
    plan_file="${CALLER_DIR}/${plan_file}"
fi

# Resolve artifact: absolute path stays as-is, relative resolved from caller's dir
if [[ "$artifact" != /* ]]; then
    artifact="${CALLER_DIR}/${artifact}"
fi

if [[ ! -f "$artifact" ]]; then
    echo "ERROR: Artifact file not found: $artifact" >&2
    exit 1
fi

# ── Classification ──────────────────────────────────────────────

# Build a single stderr string from the artifact: extract everything
# between the first '---' marker and the final '---' / exit code line.
# The artifact format is:
#   Running verify_cmd: ...
#   Plan: ...
#   Story: ...
#   Timestamp: ...
#   ---
#   <stdout+stderr>
#   ---
#   Exit code: N
stderr_block=$(awk '
    /^---$/ { if (!in_body) { in_body=1; next } else { exit } }
    in_body { print }
' "$artifact")

if [[ -z "$stderr_block" ]]; then
    exit_code_line=$(grep -E '^Exit code:' "$artifact" 2>/dev/null || echo "Exit code: -1")
    exit_code=$(echo "$exit_code_line" | grep -oE '[0-9]+' | tail -1)
    if [[ "$exit_code" =~ ^[0-9]+$ ]] && [[ "$exit_code" -eq 0 ]]; then
        echo "INFO: Exit code 0 — nothing to classify" >&2
        exit 0
    fi
    # If we can't extract a stderr block, treat as UNKNOWN
    classification="UNKNOWN"
else
    # ENVIRONMENT patterns
    if echo "$stderr_block" | grep -qE 'ModuleNotFoundError|command not found|ECONNREFUSED|No module named'; then
        classification="ENVIRONMENT"
    # TEST_FAILURE patterns
    elif echo "$stderr_block" | grep -qE 'FAILED|AssertionError|assert '; then
        classification="TEST_FAILURE"
    # Also check exit code: if exit ≠ 0 and not already classified, treat as TEST_FAILURE
    else
        exit_code_line=$(grep -E '^Exit code:' "$artifact" 2>/dev/null || echo "Exit code: -1")
        exit_code=$(echo "$exit_code_line" | grep -oE '[0-9]+' | tail -1)
        if [[ "$exit_code" =~ ^[0-9]+$ ]] && [[ "$exit_code" -ne 0 ]]; then
            classification="TEST_FAILURE"
        else
            classification="UNKNOWN"
        fi
    fi
fi

# ── Retry tracking ──────────────────────────────────────────────

# Read retry_count from plan frontmatter using Python
plan_file_win=$(cygpath -w "$plan_file" 2>/dev/null || echo "$plan_file")
retry_count=$(python -c "
import sys, re
try:
    with open(sys.argv[1]) as f:
        content = f.read()
except FileNotFoundError:
    print(0)
    sys.exit(0)
m = re.search(r'^---\s*\n(.*?)\n---\s*\n', content, re.DOTALL)
if not m:
    print(0)
    sys.exit(0)
fm = m.group(1)
rm = re.search(r'retry_count:\s*(\d+)', fm)
if rm:
    print(int(rm.group(1)))
else:
    print(0)
" "$plan_file_win")

if [[ ! "$retry_count" =~ ^[0-9]+$ ]]; then
    retry_count=0
fi

MAX_RETRIES=2
new_retry_count=$((retry_count + 1))

# ── Routing ─────────────────────────────────────────────────────

if [[ "$classification" == "ENVIRONMENT" ]]; then
    # Set plan status:blocked, halt
    echo "[feedback-loop] Classified as ENVIRONMENT — blocking plan" >&2

    python -c "
import sys, re
plan = sys.argv[1]
try:
    with open(plan) as f:
        content = f.read()
except FileNotFoundError:
    sys.exit(1)
m = re.search(r'^---\s*\n(.*?)\n---\s*\n', content, re.DOTALL)
if not m:
    sys.exit(1)
frontmatter = m.group(1)
new_fm = frontmatter
# Update or add retry_count
if re.search(r'^retry_count:', new_fm, re.MULTILINE):
    new_fm = re.sub(r'^retry_count:.*', f'retry_count: {sys.argv[2]}', new_fm, flags=re.MULTILINE)
else:
    new_fm = new_fm.rstrip() + f'\nretry_count: {sys.argv[2]}'
# Update or add status
if re.search(r'^status:', new_fm, re.MULTILINE):
    new_fm = re.sub(r'^status:.*', 'status: blocked', new_fm, flags=re.MULTILINE)
else:
    new_fm = new_fm.rstrip() + '\nstatus: blocked'

new_content = content.replace(m.group(1), new_fm, 1)
with open(plan, 'w') as f:
    f.write(new_content)
" "$plan_file_win" "$new_retry_count"

    # Write escalation artifact
    escalation_file="artifacts/${story_id}/escalation.md"
    mkdir -p "artifacts/${story_id}"
    cat > "$escalation_file" << ESCALATION_EOF
# Escalation: $story_id

**Date:** $(date -u +"%Y-%m-%dT%H:%M:%SZ")
**Classification:** ENVIRONMENT
**Task:** $task_id
**Artifact:** $artifact

## Failure Summary

The verify step failed with an **ENVIRONMENT** error — a missing dependency,
network failure, or other infrastructure issue that cannot be resolved
by re-dispatching to the coding agent.

## Evidence

\`\`\`
$(head -100 "$artifact")
\`\`\`

## Action Required

A human must resolve the environment issue before re-dispatch.
The plan file \`$plan_file\` has been set to \`status: blocked\`.
ESCALATION_EOF

    # Trace
    bash scripts/trace.sh \
        --summary "FeedbackClassified: $story_id as ENVIRONMENT (blocked)" \
        --outcome "failure" \
        --story-id "$story_id" \
        --task-id "$task_id" \
        --actor "feedback-controller"

    exit 1  # halted

elif [[ "$classification" == "TEST_FAILURE" ]]; then
    if [[ "$retry_count" -ge "$MAX_RETRIES" ]]; then
        echo "[feedback-loop] Max retries ($MAX_RETRIES) exceeded for $story_id" >&2

        # Write escalation artifact
        escalation_file="artifacts/${story_id}/escalation.md"
        mkdir -p "artifacts/${story_id}"
        cat > "$escalation_file" << ESCALATION_EOF
# Escalation: $story_id — Max Retries Exceeded

**Date:** $(date -u +"%Y-%m-%dT%H:%M:%SZ")
**Classification:** TEST_FAILURE (max retry)
**Task:** $task_id
**Attempts:** $retry_count / $MAX_RETRIES
**Artifact:** $artifact

## Failure Summary

The test failure persisted through $retry_count re-dispatch attempts.
The agent was unable to produce a passing implementation.

## Evidence

\`\`\`
$(head -100 "$artifact")
\`\`\`

## Action Required

Human review needed. The plan file \`$plan_file\` should be inspected
for specification issues, or the implementation approach reconsidered.
ESCALATION_EOF

        # Trace
        bash scripts/trace.sh \
            --summary "FeedbackClassified: $story_id max retries exceeded ($retry_count/$MAX_RETRIES)" \
            --outcome "failure" \
            --story-id "$story_id" \
            --task-id "$task_id" \
            --actor "feedback-controller"

        exit 2  # max retries exceeded
    fi

    # Re-dispatch with failure context
    echo "[feedback-loop] Classified as TEST_FAILURE — re-dispatching (attempt $new_retry_count/$MAX_RETRIES)" >&2

    # Update retry_count in plan frontmatter
    python -c "
import sys, re
plan = sys.argv[1]
try:
    with open(plan) as f:
        content = f.read()
except FileNotFoundError:
    sys.exit(1)
m = re.search(r'^---\s*\n(.*?)\n---\s*\n', content, re.DOTALL)
if not m:
    sys.exit(1)
frontmatter = m.group(1)
new_fm = frontmatter
if re.search(r'^retry_count:', new_fm, re.MULTILINE):
    new_fm = re.sub(r'^retry_count:.*', f'retry_count: {sys.argv[2]}', new_fm, flags=re.MULTILINE)
else:
    new_fm = new_fm.rstrip() + f'\nretry_count: {sys.argv[2]}'
new_content = content.replace(m.group(1), new_fm, 1)
with open(plan, 'w') as f:
    f.write(new_content)
" "$plan_file_win" "$new_retry_count"

    # Trace
    bash scripts/trace.sh \
        --summary "FeedbackClassified: $story_id as TEST_FAILURE, re-dispatching (attempt $new_retry_count/$MAX_RETRIES)" \
        --outcome "success" \
        --story-id "$story_id" \
        --task-id "$task_id" \
        --actor "feedback-controller"

    # Re-dispatch. Use set +e so we capture dispatch.sh's exit code rather than
    # letting set -e abort the script on non-zero. This keeps our exit-code
    # contract intact (0=re-dispatched, 1=halted, 2=max-retries).
    dispatch_exit=0
    if [[ -f "scripts/dispatch.sh" ]]; then
        set +e
        bash scripts/dispatch.sh \
            --plan "$plan_file" \
            --story-id "$story_id" \
            --task-id "$task_id" \
            --failure-context "$artifact"
        dispatch_exit=$?
        set -e
    else
        echo "ERROR: scripts/dispatch.sh not found — cannot re-dispatch" >&2
        exit 1
    fi

    if [[ $dispatch_exit -ne 0 ]]; then
        echo "[feedback-loop] dispatch.sh exited with code $dispatch_exit — escalating" >&2
        exit 1
    fi

    exit 0  # re-dispatched

else
    # UNKNOWN — escalate
    echo "[feedback-loop] Classified as UNKNOWN — escalating" >&2

    # Write escalation artifact
    escalation_file="artifacts/${story_id}/escalation.md"
    mkdir -p "artifacts/${story_id}"
    cat > "$escalation_file" << ESCALATION_EOF
# Escalation: $story_id — Unknown Failure

**Date:** $(date -u +"%Y-%m-%dT%H:%M:%SZ")
**Classification:** UNKNOWN
**Task:** $task_id
**Artifact:** $artifact

## Failure Summary

The verify step failed with an unrecognized error pattern.
This does not match any known M1 failure class (ENVIRONMENT, TEST_FAILURE).

## Evidence

\`\`\`
$(head -100 "$artifact")
\`\`\`

## Action Required

Human review needed to:
1. Diagnose the root cause
2. Add the pattern to the classification matrix if recurring
3. Decide whether to re-dispatch or modify the plan
ESCALATION_EOF

    # Trace
    bash scripts/trace.sh \
        --summary "FeedbackClassified: $story_id as UNKNOWN (escalated)" \
        --outcome "failure" \
        --story-id "$story_id" \
        --task-id "$task_id" \
        --actor "feedback-controller"

    exit 1  # halted
fi
