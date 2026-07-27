#!/usr/bin/env bash
set -euo pipefail

# adw.sh — AI Developer Workflow router (PRD §16)
# Usage: adw.sh --type {feature|bug|chore|hotfix} --summary "..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

adw_type=""
summary=""
lane=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --type) adw_type="$2"; shift 2 ;;
        --summary) summary="$2"; shift 2 ;;
        *) shift ;;
    esac
done

[[ -z "$adw_type" ]] && { echo "Usage: adw.sh --type {feature|bug|chore|hotfix} --summary '...' " >&2; exit 1; }

# Route per ADW type (PRD §16)
case "$adw_type" in
    feature)
        lane="normal"
        workflow="requirements-analyst → architect → [backend ∥ frontend] → integration → QA → security → human-gate → release"
        echo "[adw] Feature ADW — lane=$lane — $workflow"
        ;;
    bug)
        lane="normal"
        workflow="reproduce (failing test first) → fix → QA regression → review → ship"
        echo "[adw] Bug ADW — lane=$lane — $workflow"
        ;;
    chore)
        lane="tiny"
        workflow="single-agent → lint → CI → review → ship"
        echo "[adw] Chore ADW — lane=$lane — $workflow"
        ;;
    hotfix)
        lane="high-risk"
        workflow="hotfix-agent (surgical) → human-approve → ship → post-incident proper fix"
        echo "[adw] Hotfix ADW — lane=$lane — $workflow"
        ;;
    *)
        echo "Unknown ADW type: $adw_type" >&2
        exit 1
        ;;
esac

# Trace routing decision
bash "$REPO_ROOT/scripts/trace.sh" \
    --summary "ADWRouted: $adw_type → lane=$lane" \
    --outcome success \
    --actor "adw-router"

echo "[adw] ✓ Routed as $lane lane"
