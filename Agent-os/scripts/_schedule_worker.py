# _schedule_worker.py — DAG scheduler worker (called by schedule.sh)
import json, sys, subprocess, os

dag_file = sys.argv[1]
run_id = sys.argv[2]
repo_root = sys.argv[3]

# Convert MSYS path to Windows if needed
if repo_root.startswith('/'):
    import subprocess as sp
    result = sp.run(['cygpath', '-w', repo_root], capture_output=True, text=True)
    if result.returncode == 0:
        repo_root = result.stdout.strip()

with open(dag_file) as f:
    dag = json.load(f)

nodes = {n['id']: n for n in dag['nodes']}
completed = set()
failed = set()

def deps_met(nid):
    return all(d in completed for d in nodes[nid].get('depends_on', []))

iteration = 0
while len(completed) + len(failed) < len(nodes):
    iteration += 1
    ready = [nid for nid, n in nodes.items()
             if nid not in completed and nid not in failed and deps_met(nid)]

    if not ready:
        stuck = [nid for nid in nodes if nid not in completed and nid not in failed]
        if stuck:
            print(f'[schedule] Deadlock at: {stuck}', file=sys.stderr)
        break

    groups = {}
    for nid in ready:
        pg = nodes[nid].get('parallel_group', 'default')
        groups.setdefault(pg, []).append(nid)

    for pg, pg_nodes in groups.items():
        print(f'[schedule] Group "{pg}": {len(pg_nodes)} node(s)')
        procs = []
        for nid in pg_nodes:
            node = nodes[nid]
            print(f'  → {nid}: {node.get("name", nid)} ({node.get("agent", "?")})')
            # Simulate dispatch (real dispatch would call dispatch.sh here)
            proc = subprocess.Popen(
                [sys.executable, '-c',
                 f'import json; print(json.dumps({{"node":"{nid}","status":"completed"}}))'],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=repo_root
            )
            procs.append((nid, proc))

        for nid, proc in procs:
            stdout, stderr = proc.communicate(timeout=300)
            if proc.returncode == 0:
                completed.add(nid)
                print(f'  ✓ {nid} completed')
            else:
                failed.add(nid)
                print(f'  ✗ {nid} failed: {stderr.decode()[:80]}')

# Save result
os.makedirs(f'artifacts/{run_id}', exist_ok=True)
result = {
    'run_id': run_id,
    'completed': list(completed),
    'failed': list(failed),
    'total': len(nodes),
    'success_rate': f'{len(completed)}/{len(nodes)}'
}
with open(f'artifacts/{run_id}/schedule-result.json', 'w') as f:
    json.dump(result, f, indent=2)

print(f'[schedule] {len(completed)}/{len(nodes)} completed, {len(failed)} failed')
sys.exit(0 if not failed else 1)
