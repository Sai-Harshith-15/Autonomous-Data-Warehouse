#!/usr/bin/env bash
set -euo pipefail

# intent-gate.sh — semantic verification (No Mistakes pattern, PRD §14.3)
# Usage: intent-gate.sh --contract <contract.json> --task-id <T-...>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

contract_file=""
task_id=""
while [[ $# -gt 0 ]]; do case "$1" in --contract) contract_file="$2"; shift 2 ;; --task-id) task_id="$2"; shift 2 ;; *) shift ;; esac; done
[[ -z "$contract_file" || -z "$task_id" ]] && { echo "Usage: intent-gate.sh --contract <contract.json> --task-id <T-...>" >&2; exit 1; }

contract_win=$(cygpath -m "$contract_file" 2>/dev/null || echo "$contract_file")
agent_output="artifacts/${task_id}/agent-output.md"
review_output="artifacts/${task_id}/intent-review.md"

echo "[intent-gate] Task: $task_id"

# Read contract
goal=$(python -c "import json; c=json.load(open('$contract_win')); print(c.get('goal','')[:500])" 2>/dev/null || echo "")
acceptance=$(python -c "import json; c=json.load(open('$contract_win')); print('\n'.join(c.get('acceptance',[])))" 2>/dev/null || echo "")

# Read agent output
agent_code=""
[[ -f "$agent_output" ]] && agent_code=$(head -c 2000 "$agent_output" 2>/dev/null || echo "")

# Build review prompt
review_prompt="You are a code reviewer. Review this change for intent alignment.

## Contract Goal
$goal

## Acceptance Criteria
$acceptance

## Agent Output (code diff)
$agent_code

## Review Questions
1. Does this code satisfy the contract goal?
2. What edge cases are implied by the goal that the code does NOT handle?
3. Are there any bugs or issues?

Respond with verdict only: PASS, AUTO_FIX, ESCALATE, or FAIL.
Then list specific findings."

# Call OmniRoute for review
echo "[intent-gate] Reviewing via OmniRoute..."
review_json=$(curl -s -X POST "http://localhost:20128/api/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "$(python -c "import json; print(json.dumps({'model':'auto/reasoning:pro','messages':[{'role':'user','content':'''$review_prompt'''}],'max_tokens':500,'temperature':0,'stream':False}))")" \
    2>/dev/null || echo "")

verdict=$(python -c "
import json, sys
try:
    d = json.loads('''$review_json''')
    content = d['choices'][0]['message']['content']
    for v in ['PASS','AUTO_FIX','ESCALATE','FAIL']:
        if v in content:
            print(v)
            break
    else:
        print('UNKNOWN')
except:
    print('REVIEW_ERROR')
" 2>/dev/null || echo "REVIEW_ERROR")

# Save verdict
mkdir -p "artifacts/${task_id}"
python -c "
import json
from datetime import datetime, timezone
verdict = {
    'task_id': '$task_id',
    'verdict': '$verdict',
    'timestamp': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    'reviewer': 'auto/reasoning:pro'
}
with open('$review_output', 'w') as f:
    json.dump(verdict, f, indent=2)
"

# Trace
bash "$REPO_ROOT/scripts/trace.sh" \
    --summary "IntentReviewed: $task_id → $verdict" \
    --outcome "$([[ "$verdict" == "PASS" ]] && echo success || echo failure)" \
    --task-id "$task_id" \
    --actor "intent-gate"

echo "[intent-gate] ✓ Verdict: $verdict → $review_output"
[[ "$verdict" == "PASS" ]] && exit 0 || exit 1
