#!/usr/bin/env bash
set -euo pipefail

# dispatch.sh v3 — multi-agent: reads DAG, routes to right models in parallel
# Usage: dispatch.sh --dag <dag.json> [--phase <impl|all>]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

OMNIROUTE_URL="${OMNIROUTE_URL:-http://localhost:20128/api/v1/chat/completions}"
TIMEOUT_SECONDS="${DISPATCH_TIMEOUT:-300}"

dag_file=""
phase="all"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dag) dag_file="$2"; shift 2 ;;
        --phase) phase="$2"; shift 2 ;;
        *) echo "Unknown: $1" >&2; exit 1 ;;
    esac
done

[[ -z "$dag_file" ]] && { echo "Usage: dispatch.sh --dag <dag.json> [--phase impl|all]" >&2; exit 1; }

# Model routing per agent type
declare -A AGENT_MODELS
AGENT_MODELS["sdlc-backend-engineer"]="auto/coding:pro"
AGENT_MODELS["sdlc-frontend-engineer"]="auto/coding:fast"
AGENT_MODELS["sdlc-qa-engineer"]="auto/coding:fast"
AGENT_MODELS["sdlc-integration-engineer"]="auto/coding:pro"
AGENT_MODELS["requirements-analyst"]="auto/reasoning:pro"
AGENT_MODELS["software-architect"]="auto/reasoning:pro"
AGENT_MODELS["sdlc-security-reviewer"]="auto/coding:free"

# Agent system prompts
declare -A AGENT_PROMPTS
AGENT_PROMPTS["sdlc-backend-engineer"]="You are sdlc-backend-engineer. Write production Python backend code. Output ONLY raw code, no markdown fences. Write files to the specified outputs[] directory only."
AGENT_PROMPTS["sdlc-frontend-engineer"]="You are sdlc-frontend-engineer. Write clean HTML/CSS/JS frontend code. Output ONLY raw code, no markdown fences."
AGENT_PROMPTS["sdlc-qa-engineer"]="You are sdlc-qa-engineer. Write pytest tests. Use httpx.AsyncClient. Output ONLY raw code, no markdown fences."
AGENT_PROMPTS["requirements-analyst"]="You are requirements-analyst. Review specs, find ambiguities, define acceptance criteria. Output markdown."
AGENT_PROMPTS["software-architect"]="You are software-architect. Design architecture, write ADRs. Output markdown."

echo "[dispatch v3] Reading DAG: $dag_file"

# Parse DAG JSON
dag_win=$(cygpath -w "$dag_file" 2>/dev/null || echo "$dag_file")
nodes_json=$(python -c "import json; d=json.load(open('$dag_win')); print(json.dumps(d.get('nodes',[])))")

# Get ready nodes (dependencies satisfied)
ready_nodes=$(python -c "
import json, sys
nodes = json.loads(sys.argv[1])
phase = sys.argv[2]
ready = []
for n in nodes:
    deps = n.get('depends_on', [])
    if phase == 'impl' and n.get('parallel_group') != 'impl':
        continue
    if not deps:
        ready.append(n)
print(json.dumps(ready))
" "$nodes_json" "$phase")

count=$(python -c "import json; print(len(json.loads('$ready_nodes')))" 2>/dev/null || echo 0)
echo "[dispatch v3] Ready nodes: $count"

# Group by parallel_group for simultaneous execution
echo "$ready_nodes" | python -c "
import json, sys, subprocess, os

nodes = json.load(sys.stdin)
groups = {}
for n in nodes:
    pg = n.get('parallel_group', 'default')
    groups.setdefault(pg, []).append(n)

for pg, pg_nodes in groups.items():
    print(f'[dispatch v3] Parallel group {pg}: {len(pg_nodes)} nodes')
    pids = []
    for node in pg_nodes:
        agent = node['agent']
        model = '${AGENT_MODELS[$agent]:-auto/coding:fast}'
        system_prompt = '${AGENT_PROMPTS[$agent]:-You are a coding agent.}'
        task = node['name']
        target_dir = node.get('outputs', ['projects/output/'])[0]
        
        print(f'  → {agent} ({model}) dispatching to {target_dir}...')
        # Background dispatch via curl
        pid = os.fork()
        if pid == 0:
            # Child: dispatch to OmniRoute
            payload = json.dumps({
                'model': model,
                'messages': [
                    {'role': 'system', 'content': system_prompt},
                    {'role': 'user', 'content': f'Task: {task}\nWrite output to directories under {target_dir}. Output ONLY the code, no explanations.'}
                ],
                'max_tokens': 2000,
                'temperature': 0,
                'stream': False
            })
            import urllib.request
            req = urllib.request.Request(
                'http://localhost:20128/api/v1/chat/completions',
                data=payload.encode(),
                headers={'Content-Type': 'application/json'}
            )
            resp = urllib.request.urlopen(req, timeout=300)
            result = json.loads(resp.read())
            content = result['choices'][0]['message']['content']
            # Save to artifact
            os.makedirs(f'artifacts/{node[\"id\"]}', exist_ok=True)
            with open(f'artifacts/{node[\"id\"]}/agent-output.md', 'w') as f:
                f.write(content)
            os._exit(0)
        pids.append(pid)
    
    # Wait for all in this group
    for pid in pids:
        os.waitpid(pid, 0)
    print(f'[dispatch v3] Group {pg} complete')
" 2>&1

echo "[dispatch v3] ✓ All nodes dispatched"
