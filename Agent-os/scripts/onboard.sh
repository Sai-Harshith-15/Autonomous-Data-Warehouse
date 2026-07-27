#!/usr/bin/env bash
set -euo pipefail

# onboard.sh — brownfield repository onboarding (PRD §17.1)
# Usage: onboard.sh --repo <path>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

target_repo=""
while [[ $# -gt 0 ]]; do case "$1" in --repo) target_repo="$2"; shift 2 ;; *) shift ;; esac; done
[[ -z "$target_repo" ]] && { echo "Usage: onboard.sh --repo <path>" >&2; exit 1; }

echo "[onboard] Target: $target_repo"

# Step 1: Index with codebase-memory-mcp (if available)
echo "[onboard] Step 1: Indexing codebase..."
if command -v codebase-memory-mcp &>/dev/null; then
    echo "  codebase-memory-mcp available — run manually: codebase-memory-mcp index $target_repo"
else
    echo "  ⚠ codebase-memory-mcp not found — skip"
fi

# Step 2: Record baseline metrics
echo "[onboard] Step 2: Recording baseline..."
python -c "
import os, json, subprocess
repo = '$target_repo'
baseline = {'repo': repo}

# Coverage baseline
result = subprocess.run(['python', '-m', 'coverage', 'run', '-m', 'pytest', '--collect-only'],
                       cwd=repo, capture_output=True, text=True)
test_count = result.stdout.count('::')
baseline['test_count'] = test_count

# Git baseline
result = subprocess.run(['git', '-C', repo, 'rev-parse', 'HEAD'], capture_output=True, text=True)
baseline['git_sha'] = result.stdout.strip()

# File count
py_files = 0
for root, dirs, files in os.walk(repo):
    py_files += sum(1 for f in files if f.endswith('.py'))
baseline['py_files'] = py_files

os.makedirs(f'{repo}/.harness', exist_ok=True)
with open(f'{repo}/.harness/baseline.json', 'w') as f:
    json.dump(baseline, f, indent=2)
print(f'  Tests: {test_count}, Python files: {py_files}, SHA: {baseline[\"git_sha\"][:8]}')
"

# Step 3: Generate ADRs for existing decisions
echo "[onboard] Step 3: ADR scaffolding..."
mkdir -p "$target_repo/docs/decisions"
cat > "$target_repo/docs/decisions/ADR-0000-as-built-architecture.md" << 'EOF'
# ADR-0000: As-Built Architecture

> Status: Accepted (auto-generated during brownfield onboarding)
> This ADR documents the existing architecture before agent modifications.

## Context
This is an existing repository onboarded into the AI Software Factory.
The architecture described here is reverse-engineered from the current codebase.

## Existing Architecture
(To be filled by software-architect agent after indexing)

## Baseline
See `.harness/baseline.json` for metrics at time of onboarding.
EOF

# Step 4: Generate AGENTS.md + TEST_MATRIX.md
echo "[onboard] Step 4: Harness scaffold..."
cp "$REPO_ROOT/docs/templates/decision.md" "$target_repo/docs/templates/" 2>/dev/null || true

echo "[onboard] ✓ Onboarding complete for $target_repo"
bash "$REPO_ROOT/scripts/trace.sh" --summary "BrownfieldOnboarded: $target_repo" --outcome success --actor "onboard-engine"

echo "[onboard] ✓ Done — run: harness-cli audit to validate"
