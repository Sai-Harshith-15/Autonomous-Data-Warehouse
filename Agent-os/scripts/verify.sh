#!/usr/bin/env bash
set -euo pipefail

# verify.sh v2 — run verify_cmd with evidence cache
# Usage: verify.sh --plan <plan.md> --story-id <US-XXXX> [--run-id <R-...>] [--flush-cache]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CALLER_DIR="$(pwd)"
cd "$REPO_ROOT"

plan_file=""
story_id=""
run_id=""
flush_cache=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --plan)        plan_file="$2";  shift 2 ;;
        --story-id)    story_id="$2";   shift 2 ;;
        --run-id)      run_id="$2";     shift 2 ;;
        --flush-cache) flush_cache=true; shift ;;
        *) echo "Unknown: $1" >&2; exit 1 ;;
    esac
done

[[ -z "$plan_file" || -z "$story_id" ]] && { echo "Usage: verify.sh --plan <plan.md> --story-id <US-XXXX> [--run-id <R-...>]" >&2; exit 1; }

# Resolve plan path
if [[ "$plan_file" != /* ]]; then
    plan_file="${CALLER_DIR}/${plan_file}"
fi

# Get git SHA for cache key
git_sha=$(git rev-parse HEAD 2>/dev/null || echo "unknown")

# Convert MSYS path to Windows for Python
plan_win=$(cygpath -w "$plan_file" 2>/dev/null || echo "$plan_file")

# Extract verify_cmd from YAML frontmatter using Python file read (avoids shell variable quoting issues)
verify_cmd=$(python -c "
import sys, re
plan = sys.argv[1]
try:
    with open(plan) as f:
        content = f.read()
except FileNotFoundError:
    sys.exit(1)
m = re.search(r'^---\s*\n(.*?)\n---\s*\n', content, re.DOTALL)
if not m:
    print('', end=''); sys.exit(0)
frontmatter = m.group(1)
vm = re.search(r'verify_cmd:\s*(.+)', frontmatter)
if vm:
    val = vm.group(1).strip()
    if (val.startswith('\"') and val.endswith('\"')) or (val.startswith(\"'\") and val.endswith(\"'\")):
        val = val[1:-1]
    print(val, end='')
" "$plan_win")

if [[ -z "$verify_cmd" ]]; then
    echo "No verify_cmd found in: $plan_file" >&2
    exit 1
fi

# Compute cache key
gate_name="verify-${story_id}"
cache_key=$(echo -n "${git_sha}|${gate_name}" | sha256sum | cut -d' ' -f1)

HARNESS_DB="${HARNESS_DB:-D:/agent-os/harness.db}"

# ─── Evidence Cache Check ──────────────────────────────────────────────
if [[ "$flush_cache" == false ]]; then
    cached=$(python -c "
import sqlite3, sys
try:
    conn = sqlite3.connect('${HARNESS_DB}', timeout=10)
    row = conn.execute('SELECT outcome, exit_code FROM gates WHERE cache_key=? AND invalidated=0 AND expires_at > datetime(\"now\")', ('${cache_key}',)).fetchone()
    if row:
        print(f'CACHED|{row[0]}|{row[1]}')
    conn.close()
except Exception:
    pass
" 2>/dev/null || echo "")

    if [[ "$cached" == CACHED* ]]; then
        IFS='|' read -r _ outcome cached_exit <<< "$cached"
        echo "[verify] CACHE HIT: $gate_name → $outcome (exit: $cached_exit)"
        bash scripts/trace.sh --run-id "${run_id:-unknown}" --event-type "gate_passed" \
            --summary "Cached: $story_id" --outcome "$outcome" --gate "$gate_name"
        exit "$cached_exit"
    fi
fi

echo "[verify] Running: $verify_cmd"

# Create output dirs
artifact_dir="artifacts/${story_id}"
mkdir -p "$artifact_dir"

output_file="${artifact_dir}/verify-output.txt"
evidence_file="${artifact_dir}/evidence.sha256"
task_dir="/d/agent-os/runs/${run_id:-local}/tasks/${story_id}"
mkdir -p "$task_dir"

# Run verification
{
    echo "Running verify_cmd: $verify_cmd"
    echo "Plan: $plan_file"
    echo "Story: $story_id"
    echo "Git SHA: $git_sha"
    echo "Timestamp: $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    echo "Cache key: $cache_key"
    echo "---"
} > "$output_file"

start_ms=$(python -c "import time; print(int(time.time() * 1000))")

set +e
(eval "$verify_cmd") >> "$output_file" 2>&1
exit_code=$?
set -e

end_ms=$(python -c "import time; print(int(time.time() * 1000))")
elapsed_ms=$((end_ms - start_ms))

echo "---" >> "$output_file"
echo "Exit code: $exit_code" >> "$output_file"
echo "Elapsed: ${elapsed_ms}ms" >> "$output_file"

cp "$output_file" "${task_dir}/stdout.log" 2>/dev/null || true
sha256sum "$output_file" | awk '{print $1}' > "$evidence_file"

if [[ $exit_code -eq 0 ]]; then
    outcome="pass"
else
    outcome="fail"
fi

# ─── Store in evidence cache ──────────────────────────────────────────
# Write cache to a temp Python script to avoid quoting issues with shell variables in inline Python
python -c "
import sqlite3, sys, json
DB = '${HARNESS_DB}'
try:
    conn = sqlite3.connect(DB, timeout=10)
    conn.execute('PRAGMA journal_mode=WAL')
    # Read the verify_cmd from the output file to avoid quoting issues
    cmd = open('${output_file}').readline().replace('Running verify_cmd: ', '').strip()
    conn.execute('''INSERT OR REPLACE INTO gates
                    (run_id, task_id, gate_name, git_sha, cache_key, outcome,
                     exit_code, command, stdout_path, elapsed_ms, expires_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?,
                            datetime(\"now\", \"+24 hours\"))''',
                ('${run_id:-unknown}', '${story_id}', '${gate_name}',
                 '${git_sha}', '${cache_key}', '${outcome}', ${exit_code},
                 cmd, '${output_file}', ${elapsed_ms}))
    conn.commit()
    conn.close()
except Exception as e:
    import sys
    print(f'[verify] Cache store warning: {e}', file=sys.stderr)
"

# Trace event
bash scripts/trace.sh --run-id "${run_id:-unknown}" --event-type "gate_${outcome}" \
    --summary "GateChecked: $story_id" --outcome "$outcome" --gate "$gate_name" \
    --elapsed-ms "$elapsed_ms"

echo "[verify] Exit: $exit_code, Elapsed: ${elapsed_ms}ms"
exit $exit_code
