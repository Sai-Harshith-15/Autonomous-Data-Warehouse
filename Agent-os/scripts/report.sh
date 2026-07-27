#!/usr/bin/env bash
# report.sh — AI Software Factory weekly summary from events/*.jsonl trace logs
# Usage: scripts/report.sh [--weekly | --run <R-...> | --all]
set -euo pipefail

# ---------------------------------------------------------------------------
# cwd-independent resolution of repo root (Windows-native paths for Python)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Convert MSYS paths (e.g. /d/foo) to Windows-native (D:/foo) so Python can
# resolve them.  Falls back to the original path when cygpath is absent.
_to_win() {
    if command -v cygpath &>/dev/null; then
        cygpath -m "$1"
    else
        echo "$1"
    fi
}

EVENTS_DIR="$(_to_win "$REPO_ROOT/events")"
REPORTS_DIR="$(_to_win "$REPO_ROOT/docs/reports")"

# ---------------------------------------------------------------------------
# usage & arg parsing
# ---------------------------------------------------------------------------
usage() {
    cat <<'EOF'
Usage: report.sh [--weekly | --run <R-...> | --all]

Generate a summary report from events/*.jsonl trace logs.

Options:
  --weekly    Filter to last 7 days, write to docs/reports/weekly-YYYY-WNN.md
  --run <id>  Filter to a specific run_id (e.g., R-20260726-001)
  --all       Report on all events (default)
EOF
    exit 1
}

MODE="all"
RUN_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --weekly) MODE="weekly"; shift ;;
        --run)
            if [[ $# -lt 2 ]]; then usage; fi
            MODE="run"
            RUN_ID="$2"
            shift 2
            ;;
        --all) MODE="all"; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# ---------------------------------------------------------------------------
# ensure output directory exists
# ---------------------------------------------------------------------------
mkdir -p "$REPORTS_DIR"

# ---------------------------------------------------------------------------
# inline Python: parse JSONL, compute stats, emit markdown
# ---------------------------------------------------------------------------
EVENTS_DIR="$EVENTS_DIR" MODE="$MODE" RUN_ID="${RUN_ID:-}" REPORTS_DIR="$REPORTS_DIR" python << 'PYEOF'
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from collections import defaultdict

events_dir  = os.environ["EVENTS_DIR"]
mode        = os.environ["MODE"]
run_id      = os.environ.get("RUN_ID", "")
reports_dir = os.environ["REPORTS_DIR"]

# ------------------------------------------------------------------ read all JSONL files
events = []
if os.path.isdir(events_dir):
    for fname in sorted(os.listdir(events_dir)):
        if not fname.endswith(".jsonl"):
            continue
        fpath = os.path.join(events_dir, fname)
        try:
            with open(fpath, encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        events.append(json.loads(line))
                    except json.JSONDecodeError:
                        print(f"[WARN] skipping malformed line in {fname}", file=sys.stderr)
        except OSError as exc:
            print(f"[WARN] cannot read {fname}: {exc}", file=sys.stderr)
else:
    print(f"[WARN] events directory not found: {events_dir}", file=sys.stderr)

# ------------------------------------------------------------------ filter
if mode == "weekly":
    cutoff = (datetime.now(timezone.utc) - timedelta(days=7)).isoformat()
    events = [e for e in events if e.get("ts", "") >= cutoff]
elif mode == "run" and run_id:
    events = [e for e in events if e.get("run_id", "") == run_id]

# ------------------------------------------------------------------ compute stats
total = len(events)

# Events by type (the `event` field)
type_counts = defaultdict(int)
for e in events:
    etype = e.get("event") or "unknown"
    type_counts[etype] += 1

# Outcomes
success_count = sum(1 for e in events if e.get("outcome") == "success")
failure_count = sum(1 for e in events if e.get("outcome") == "failure")
other_outcomes = total - success_count - failure_count

# Unique IDs (discard None / empty)
run_ids    = {e["run_id"] for e in events if e.get("run_id")}
story_ids  = {e["story_id"] for e in events if e.get("story_id")}
task_ids   = {e["task_id"] for e in events if e.get("task_id")}

# Success rate (success / (success + failure), ignoring "unknown" outcomes)
denom = success_count + failure_count
success_rate = (success_count / denom * 100) if denom > 0 else 0.0

# ------------------------------------------------------------------ build markdown
now = datetime.now()
date_str = now.strftime("%Y-%m-%d")

desc = {
    "all":    "all events",
    "weekly": "last 7 days",
    "run":    f"run {run_id}",
}.get(mode, mode)

lines = []
lines.append(f"## Report {date_str} ({desc})")
lines.append("")
lines.append("| Metric | Value |")
lines.append("|--------|-------|")
lines.append(f"| Total events | {total} |")

# Event-type breakdown rows
for etype in sorted(type_counts):
    lines.append(f"| {etype} | {type_counts[etype]} |")

lines.append(f"| Success count | {success_count} |")
lines.append(f"| Failure count | {failure_count} |")

if other_outcomes:
    lines.append(f"| Other outcomes | {other_outcomes} |")

lines.append(f"| Success rate | {success_rate:.0f}% |")
lines.append(f"| Unique run IDs | {len(run_ids)} |")
lines.append(f"| Unique story IDs | {len(story_ids)} |")
lines.append(f"| Unique task IDs | {len(task_ids)} |")
lines.append("")

output = "\n".join(lines)

# ------------------------------------------------------------------ emit
if mode == "weekly":
    iso_year, iso_week, _ = now.isocalendar()
    fname = f"weekly-{iso_year}-W{iso_week:02d}.md"
    outpath = os.path.join(reports_dir, fname)
    with open(outpath, "w", encoding="utf-8") as fh:
        fh.write(output + "\n")
    print(f"Wrote: {outpath}")
else:
    print(output)
PYEOF
