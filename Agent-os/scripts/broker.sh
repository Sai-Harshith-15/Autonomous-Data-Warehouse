#!/usr/bin/env bash
set -euo pipefail

# broker.sh — Capability Broker: enforce sandbox tiers from contract (M4)
# Usage: broker.sh --contract <contract.json> --task-id <T-...>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

contract_file=""
task_id=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --contract) contract_file="$2"; shift 2 ;;
        --task-id) task_id="$2"; shift 2 ;;
        *) shift ;;
    esac
done
[[ -z "$contract_file" ]] && { echo "Usage: broker.sh --contract <contract.json> --task-id <T-...>" >&2; exit 1; }

# Resolve to absolute path from REPO_ROOT
[[ "$contract_file" != /* ]] && contract_file="${REPO_ROOT}/${contract_file}"
# Convert to Windows path for Python open()
contract_win=$(cygpath -m "$contract_file" 2>/dev/null || echo "$contract_file")

echo "[broker] Reading contract: $contract_file"

# Parse contract and enforce tier
eval $(python -c "
import json, sys

with open(sys.argv[1]) as f:
    c = json.load(f)

tier = c.get('sandbox_tier', 'T1')
outputs = c.get('outputs', [])
task_id = c.get('task_id', 'unknown')

# Tier enforcement
tiers = {
    'T0': {'name':'Read-only','write':False,'network':False,'tools':'read,search,mcp','deny':'write,exec,network,git-push,secrets'},
    'T1': {'name':'Worktree','write':True,'network':False,'tools':'read,write,exec,git-commit,mcp','deny':'git-push,secrets,docker,network-external'},
    'T2': {'name':'Container','write':True,'network':True,'tools':'read,write,exec,git-commit,docker,mcp','deny':'git-push,secrets,host-fs'},
    'T3': {'name':'Host+Approval','write':True,'network':True,'tools':'all','deny':'none'},
}

config = tiers.get(tier, tiers['T1'])
print(f'BROKER_TIER={tier}')
print(f'BROKER_TIER_NAME={config[\"name\"]}')
print(f'BROKER_ALLOWED_TOOLS=\"{config[\"tools\"]}\"')
print(f'BROKER_DENIED_TOOLS=\"{config[\"deny\"]}\"')
print(f'BROKER_WRITE_ENABLED={\"true\" if config[\"write\"] else \"false\"}')
print(f'BROKER_OUTPUTS=\"{json.dumps(outputs)}\"')
print(f'BROKER_TASK_ID={task_id}')
" "$contract_win")

echo "[broker] Tier: $BROKER_TIER ($BROKER_TIER_NAME)"
echo "[broker] Allowed: $BROKER_ALLOWED_TOOLS"
echo "[broker] Denied:  $BROKER_DENIED_TOOLS"

# Export env vars for downstream agent processes
export BROKER_TIER BROKER_TIER_NAME BROKER_ALLOWED_TOOLS BROKER_DENIED_TOOLS BROKER_WRITE_ENABLED BROKER_OUTPUTS BROKER_TASK_ID

# Trace
bash "$REPO_ROOT/scripts/trace.sh" \
    --summary "BrokerEnforced: $BROKER_TASK_ID → $BROKER_TIER ($BROKER_TIER_NAME)" \
    --outcome success \
    --task-id "$BROKER_TASK_ID" \
    --actor "capability-broker"

echo "[broker] ✓ Tier $BROKER_TIER enforced for $BROKER_TASK_ID"
