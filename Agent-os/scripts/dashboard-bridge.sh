#!/usr/bin/env bash
set -euo pipefail

# dashboard-bridge.sh — feed factory events to d:/agent-os dashboard (M6)
# Usage: bash scripts/dashboard-bridge.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

DASHBOARD_DIR="/d/agent-os"
EVENTS_DIR="$REPO_ROOT/events"

# Convert to Windows paths for Python
EVENTS_WIN=$(cygpath -w "$EVENTS_DIR" 2>/dev/null || echo "$EVENTS_DIR")
DASHBOARD_WIN=$(cygpath -w "$DASHBOARD_DIR" 2>/dev/null || echo "$DASHBOARD_DIR")

echo "[dashboard] Events: $EVENTS_DIR"
echo "[dashboard] Dashboard: $DASHBOARD_DIR"

python -c "
import json, os, glob
from datetime import datetime
from collections import Counter

events_dir = r'$EVENTS_WIN'
dboard = r'$DASHBOARD_WIN'

events = []
for fn in sorted(glob.glob(os.path.join(events_dir, '*.jsonl'))):
    with open(fn) as f:
        for line in f:
            try: events.append(json.loads(line))
            except: pass

summary = {
    'factory': 'AI Software Factory',
    'updated': datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
    'total_events': len(events),
    'success_rate': f'{sum(1 for e in events if e.get(\"outcome\")==\"success\")}/{len(events)}' if events else '0/0',
    'event_types': {k: v for k, v in Counter(e.get('event','Trace') for e in events).most_common(10)},
    'actors': {k: v for k, v in Counter(e.get('actor','?') for e in events).most_common(10)},
    'stories': len(set(e.get('story_id','') for e in events if e.get('story_id'))),
    'tasks': len(set(e.get('task_id','') for e in events if e.get('task_id'))),
    'recent': events[-5:] if events else []
}

public_dir = os.path.join(dboard, 'public')
os.makedirs(public_dir, exist_ok=True)
out = os.path.join(public_dir, 'factory-events.json')
with open(out, 'w') as f:
    json.dump(summary, f, indent=2)

print(f'[dashboard] {len(events)} events → {out}')
"

echo "[dashboard] ✓ Bridge complete — dashboard reads /public/factory-events.json"
