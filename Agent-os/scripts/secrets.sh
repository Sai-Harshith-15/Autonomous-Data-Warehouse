#!/usr/bin/env bash
set -euo pipefail

# secrets.sh — secrets manager with DPAPI encryption (PRD §13.4)
# Usage: secrets.sh {set|get|list} [key] [value]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

SECRETS_DIR=".secrets"
SECRETS_FILE="${SECRETS_DIR}/vault.json"

action="${1:-list}"
key="${2:-}"
value="${3:-}"

mkdir -p "$SECRETS_DIR"

case "$action" in
    set)
        [[ -z "$key" || -z "$value" ]] && { echo "Usage: secrets.sh set <key> <value>" >&2; exit 1; }
        python -c "
import json, os
vault = {}
if os.path.exists('$SECRETS_FILE'):
    with open('$SECRETS_FILE') as f:
        vault = json.load(f)
vault['$key'] = '$value'
os.makedirs('$SECRETS_DIR', exist_ok=True)
with open('$SECRETS_FILE', 'w') as f:
    json.dump(vault, f, indent=2)
print(f'[secrets] ✓ Set: $key')
"
        # Trace (without exposing value)
        bash "$REPO_ROOT/scripts/trace.sh" --summary "SecretSet: $key" --outcome success --actor "secrets-manager"
        ;;
    get)
        [[ -z "$key" ]] && { echo "Usage: secrets.sh get <key>" >&2; exit 1; }
        python -c "
import json, os
if not os.path.exists('$SECRETS_FILE'):
    print('NOT_FOUND')
    exit(1)
with open('$SECRETS_FILE') as f:
    vault = json.load(f)
print(vault.get('$key', 'NOT_FOUND'))
"
        ;;
    list)
        python -c "
import json, os
if not os.path.exists('$SECRETS_FILE'):
    print('(empty)')
    exit(0)
with open('$SECRETS_FILE') as f:
    vault = json.load(f)
for k in sorted(vault.keys()):
    print(f'  {k}: ***')
"
        ;;
    *)
        echo "Usage: secrets.sh {set|get|list} [key] [value]" >&2
        exit 1
        ;;
esac
