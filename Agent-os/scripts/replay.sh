#!/usr/bin/env bash
set -euo pipefail

# replay.sh — replay events from JSONL log (M7)
# Usage: replay.sh [--run <R-...>] [--since <date>] [--dry-run]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

run_id=""
since=""
dry_run=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run) run_id="$2"; shift 2 ;;
        --since) since="$2"; shift 2 ;;
        --dry-run) dry_run=true; shift ;;
        *) shift ;;
    esac
done

echo "[replay] Scanning events..."

python -c "
import json, os, sys
from datetime import datetime

run_filter = '$run_id' if '$run_id' else None
since_date = '$since' if '$since' else None
dry = '$dry_run' == 'true'

events = []
for fn in sorted(os.listdir('events')):
    if fn.endswith('.jsonl'):
        with open(os.path.join('events', fn)) as f:
            for line in f:
                try:
                    e = json.loads(line)
                    if run_filter and e.get('run_id') != run_filter:
                        continue
                    if since_date and e.get('ts', '')[:10] < since_date:
                        continue
                    events.append(e)
                except: pass

# Summarize
from collections import Counter
event_types = Counter(e.get('event','Trace') for e in events)
outcomes = Counter(e.get('outcome','unknown') for e in events)
actors = Counter(e.get('actor','?') for e in events)

print(f'[replay] {len(events)} events')
print(f'  Types: {dict(event_types)}')
print(f'  Outcomes: success={outcomes.get(\"success\",0)} failure={outcomes.get(\"failure\",0)}')
print(f'  Actors: {dict(actors.most_common(5))}')

# Replay timeline
if events:
    first = events[0]['ts']
    last = events[-1]['ts']
    print(f'  Timeline: {first} → {last}')

# Compute key metrics
stories = set(e.get('story_id','') for e in events if e.get('story_id'))
tasks = set(e.get('task_id','') for e in events if e.get('task_id'))
runs = set(e.get('run_id','') for e in events if e.get('run_id'))
print(f'  Unique: {len(stories)} stories, {len(tasks)} tasks, {len(runs)} runs')

with open('artifacts/replay-summary.json', 'w') as f:
    json.dump({
        'total_events': len(events),
        'event_types': dict(event_types),
        'outcomes': dict(outcomes),
        'stories': len(stories),
        'tasks': len(tasks),
        'runs': len(runs),
        'replayed_at': datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
    }, f, indent=2)

print('[replay] ✓ Summary saved to artifacts/replay-summary.json')
"

bash "$REPO_ROOT/scripts/trace.sh" --summary "ReplayComplete" --outcome success --actor "replay-engine"
echo "[replay] ✓ Done"
