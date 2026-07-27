#!/usr/bin/env bash
set -euo pipefail

# proposals.sh — self-healing proposal system (PRD §23.5)
# Usage: proposals.sh {file|list|review} [--id PROP-NNNN] [--kind skill-repair|rule-repair|doc-drift]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

PROPOSALS_DIR="docs/proposals"
mkdir -p "$PROPOSALS_DIR"

action="${1:-list}"
shift || true

case "$action" in
    file)
        # File a repair proposal
        kind=""; target=""; defect=""; fix=""; workaround=""; filed_by=""; task_id=""
        while [[ $# -gt 0 ]]; do
            case "$1" in --kind) kind="$2"; shift 2 ;; --target) target="$2"; shift 2 ;; --defect) defect="$2"; shift 2 ;;
                --fix) fix="$2"; shift 2 ;; --workaround) workaround="$2"; shift 2 ;; --task-id) task_id="$2"; shift 2 ;;
                *) shift ;; esac
        done
        
        # Find next PROP number
        prop_num=$(ls "$PROPOSALS_DIR"/PROP-*.md 2>/dev/null | wc -l)
        prop_num=$((prop_num + 1))
        prop_id=$(printf "PROP-%04d" $prop_num)
        
        cat > "$PROPOSALS_DIR/${prop_id}.md" << EOF
---
id: $prop_id
kind: ${kind:-rule-repair}
target: ${target:-unknown}
filed_by: ${filed_by:-agent}
task_id: ${task_id:-unknown}
filed_at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
status: pending
---

## Defect Observed
${defect:-No defect description provided.}

## Proposed Fix
${fix:-No fix proposed.}

## Workaround Currently In Use
${workaround:-None.}
EOF
        echo "[proposals] ✓ Filed: $prop_id → $PROPOSALS_DIR/${prop_id}.md"
        bash "$REPO_ROOT/scripts/trace.sh" --summary "ProposalFiled: $prop_id" --outcome success --actor "self-healing"
        ;;
    
    list)
        echo "[proposals] Open proposals:"
        for f in "$PROPOSALS_DIR"/PROP-*.md; do
            [[ -f "$f" ]] || continue
            id=$(basename "$f" .md)
            status=$(grep "status:" "$f" 2>/dev/null | head -1 | cut -d: -f2 | tr -d ' ')
            kind=$(grep "kind:" "$f" 2>/dev/null | head -1 | cut -d: -f2 | tr -d ' ')
            echo "  $id [$status] $kind"
        done
        ;;
    
    review)
        prop_id=""; decision="accept"
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --id) prop_id="$2"; shift 2 ;;
                accept|reject) decision="$1"; shift ;;
                *) shift ;;
            esac
        done
        prop_file="$PROPOSALS_DIR/${prop_id}.md"
        [[ ! -f "$prop_file" ]] && { echo "Proposal not found: $prop_id" >&2; exit 1; }
        
        if [[ "$decision" == "accept" ]]; then
            python -c "
import re
with open('$prop_file') as f: content = f.read()
content = re.sub(r'status:.*', 'status: accepted', content)
content += '\n**Reviewed:** $(date -u +"%Y-%m-%dT%H:%M:%SZ") — ACCEPTED\n'
with open('$prop_file', 'w') as f: f.write(content)
"
            echo "[proposals] ✓ $prop_id ACCEPTED"
        else
            python -c "
import re
with open('$prop_file') as f: content = f.read()
content = re.sub(r'status:.*', 'status: rejected', content)
with open('$prop_file', 'w') as f: f.write(content)
"
            echo "[proposals] ✗ $prop_id REJECTED"
        fi
        bash "$REPO_ROOT/scripts/trace.sh" --summary "ProposalReviewed: $prop_id → $decision" --outcome success --actor "self-healing"
        ;;
    
    *)
        echo "Usage: proposals.sh {file|list|review} [args]" >&2; exit 1 ;;
esac
