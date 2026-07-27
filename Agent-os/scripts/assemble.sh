#!/usr/bin/env bash
set -euo pipefail
# assemble.sh — collect parallel agent outputs, write files, run verify
# Usage: assemble.sh --story-id US-0001

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

story_id="${1:-US-0001}"
project_dir="projects/fastapi-health"

echo "[assemble] Story: $story_id"
echo "[assemble] Project: $project_dir"

# Find all agent responses
shopt -s nullglob
responses=(artifacts/T-PAR-*-response.json)
if [[ ${#responses[@]} -eq 0 ]]; then
    echo "[assemble] No agent responses found"
    exit 1
fi

echo "[assemble] Found ${#responses[@]} agent responses"

mkdir -p "$project_dir/tests"

# Process each response
passed=0
failed=0

for resp in "${responses[@]}"; do
    agent_id=$(echo "$resp" | grep -oP 'T-PAR-\d+')
    echo "[assemble] Processing $agent_id..."
    
    # Extract content from OpenAI response
    content=$(python -c "
import json, sys
with open('$resp') as f:
    data = json.load(f)
choice = data.get('choices', [{}])[0]
msg = choice.get('message', {})
print(msg.get('content', ''))
" 2>/dev/null || echo "")
    
    if [[ -z "$content" ]]; then
        echo "[assemble]   ✗ Empty response from $agent_id"
        ((failed++))
        continue
    fi
    
    # Save raw output
    echo "$content" > "artifacts/${agent_id}-content.txt"
    
    # Route content to appropriate file based on content analysis
    if echo "$content" | grep -q "from fastapi import FastAPI\|uvicorn.run\|@app.get"; then
        echo "$content" > "$project_dir/main.py"
        echo "[assemble]   → main.py (${#content} chars)"
        ((passed++))
    elif echo "$content" | grep -q "pytest.mark.asyncio\|from main import app\|test_health"; then
        echo "$content" > "$project_dir/tests/test_health.py"
        echo "[assemble]   → tests/test_health.py (${#content} chars)"
        ((passed++))
    elif echo "$content" | grep -q "\[project\]\|pyproject\|fastapi-health"; then
        echo "$content" > "$project_dir/pyproject.toml"
        echo "[assemble]   → pyproject.toml (${#content} chars)"
        ((passed++))
    elif echo "$content" | grep -q "uvicorn\|PORT.*8000\|#!/bin/bash"; then
        echo "$content" > "$project_dir/run.sh"
        chmod +x "$project_dir/run.sh"
        echo "[assemble]   → run.sh (${#content} chars)"
        ((passed++))
    elif echo "$content" | grep -q "^#\|^##\|FastAPI\|Health\|README"; then
        echo "$content" > "$project_dir/README.md"
        echo "[assemble]   → README.md (${#content} chars)"
        ((passed++))
    else
        # Unknown content — save to artifacts for manual review
        echo "$content" > "artifacts/${agent_id}-unrouted.txt"
        echo "[assemble]   ? unrouted (${#content} chars) — saved to artifacts/${agent_id}-unrouted.txt"
        ((passed++))
    fi
done

echo ""
echo "[assemble] Results: $passed routed, $failed failed"
echo "[assemble] Files in $project_dir/:"
ls -la "$project_dir/" 2>/dev/null | grep -v "^total\|^d" | awk '{print "  " $NF " (" $5 " bytes)"}'

if [[ $failed -gt 0 ]]; then
    exit 1
fi
exit 0
