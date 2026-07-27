#!/usr/bin/env bash
set -euo pipefail

# circuit-breaker.sh — halt on repeated failures (PRD §15.3)
# Usage: circuit-breaker.sh --run-id <R-...> [--threshold 3]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

run_id=""
threshold=3
while [[ $# -gt 0 ]]; do case "$1" in --run-id) run_id="$2"; shift 2 ;; --threshold) threshold="$2"; shift 2 ;; *) shift ;; esac; done
[[ -z "$run_id" ]] && { echo "Usage: circuit-breaker.sh --run-id <R-...> [--threshold 3]" >&2; exit 1; }

echo "[breaker] Run: $run_id, Threshold: $threshold"

# Count failures per class from events
most_common_class=$(python -c "
import json, sys, os
from collections import Counter

classes = Counter()
for fn in os.listdir('events'):
    if fn.endswith('.jsonl'):
        with open(os.path.join('events', fn)) as f:
            for line in f:
                try:
                    e = json.loads(line)
                    if e.get('run_id') == '$run_id' and e.get('outcome') == 'failure':
                        summary = e.get('summary', '')
                        if 'TEST_FAILURE' in summary: classes['TEST_FAILURE'] += 1
                        elif 'ENVIRONMENT' in summary: classes['ENVIRONMENT'] += 1
                        elif 'CONTRACT_VIOLATION' in summary: classes['CONTRACT_VIOLATION'] += 1
                        elif 'INTENT_MISMATCH' in summary: classes['INTENT_MISMATCH'] += 1
                        elif 'BUDGET_EXCEEDED' in summary: classes['BUDGET_EXCEEDED'] += 1
                        else: classes['UNKNOWN'] += 1
                except: pass

if classes:
    most_common = classes.most_common(1)[0]
    print(f'{most_common[0]} {most_common[1]}')
else:
    print('NONE 0')
" 2>/dev/null || echo "NONE 0")

class_name=$(echo "$most_common_class" | awk '{print $1}')
class_count=$(echo "$most_common_class" | awk '{print $2}')

if [[ "$class_name" != "NONE" && "$class_count" -ge "$threshold" ]]; then
    echo "[breaker] ⚠ CIRCUIT BREAKER TRIPPED: $class_count $class_name failures in $run_id"
    touch HALT
    bash "$REPO_ROOT/scripts/trace.sh" \
        --summary "RunHalted: $run_id — $class_count $class_name failures exceeded threshold $threshold" \
        --outcome failure \
        --actor "circuit-breaker"
    echo "[breaker] ✗ HALT file created. Run paused."
    exit 1
else
    echo "[breaker] ✓ OK — ${class_count} ${class_name} failures (threshold: $threshold)"
    exit 0
fi
