#!/usr/bin/env bash
set -euo pipefail

# schedule.sh — DAG scheduler with parallel group execution (M3)
# Usage: schedule.sh --dag <dag.json> --run-id <R-...>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

dag_file=""
run_id="${1:-R-$(date -u +%Y-%m-%d)-001}"

while [[ $# -gt 0 ]]; do
    case "$1" in --dag) dag_file="$2"; shift 2 ;; --run-id) run_id="$2"; shift 2 ;; *) shift ;; esac
done
[[ -z "$dag_file" ]] && { echo "Usage: schedule.sh --dag <dag.json>" >&2; exit 1; }

dag_win=$(cygpath -w "$dag_file" 2>/dev/null || echo "$dag_file")
python -c "
import json, sys, subprocess, os, time

dag = json.load(open(sys.argv[1]))
nodes = {n['id']: {**n, 'status': 'pending'} for n in dag['nodes']}
completed = set()
run_id = sys.argv[2]

def all_deps_done(node):
    return all(d in completed for d in node.get('depends_on', []))

iteration = 0
while len(completed) < len(nodes):
    iteration += 1
    ready = [n for nid, n in nodes.items() if nid not in completed and all_deps_done(n)]
    if not ready:
        stuck = [nid for nid, n in nodes.items() if nid not in completed]
        print(f'[schedule] ⚠ No ready nodes. Stuck: {stuck}', file=sys.stderr)
        break
    
    # Group by parallel_group
    groups = {}
    for n in ready:
        pg = n.get('parallel_group', 'default')
        groups.setdefault(pg, []).append(n)
    
    for pg, pg_nodes in groups.items():
        print(f'[schedule] Group {pg}: {len(pg_nodes)} nodes → dispatching...')
        pids = []
        for n in pg_nodes:
            pid = os.fork()
            if pid == 0:
                os.chdir(sys.argv[3])  # repo root
                cmd = ['bash', 'scripts/dispatch.sh', '--dag', sys.argv[1]]
                os.execvp('bash', cmd)
            pids.append((pid, n['id']))
        
        for pid, nid in pids:
            _, exit_code = os.waitpid(pid, 0)
            status = 'completed' if os.WIFEXITED(exit_code) and os.WEXITSTATUS(exit_code) == 0 else 'failed'
            nodes[nid]['status'] = status
            if status == 'completed':
                completed.add(nid)
                print(f'  ✓ {nid} completed')
            else:
                print(f'  ✗ {nid} failed (exit {os.WEXITSTATUS(exit_code)})')
    
    time.sleep(0.5)

# Save result
os.makedirs(f'artifacts/{run_id}', exist_ok=True)
result = {'run_id': run_id, 'nodes': {nid: n['status'] for nid, n in nodes.items()}, 'completed': len(completed), 'total': len(nodes)}
with open(f'artifacts/{run_id}/schedule-result.json', 'w') as f:
    json.dump(result, f, indent=2)
print(f'[schedule] ✓ {len(completed)}/{len(nodes)} nodes completed')
" "$dag_win" "${run_id}" "$(cygpath -w "$REPO_ROOT" 2>/dev/null || echo "$REPO_ROOT")"

# Trace
bash "$REPO_ROOT/scripts/trace.sh" --summary "ScheduleComplete: $run_id" --outcome success --actor "scheduler"

echo "[schedule] ✓ Done"
