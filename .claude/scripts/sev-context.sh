#!/usr/bin/env bash
# sev-context.sh — Gather structured cluster context for post-mortem triage
# Used by sev-triage agent and available to all pipeline stages
set -euo pipefail

KUBECONFIG="${KUBECONFIG:-/Users/viktorbarzin/code/infra/config}"
INFRA_DIR="${INFRA_DIR:-/Users/viktorbarzin/code/infra}"
export KUBECONFIG

echo "=== NODE STATUS ==="
kubectl get nodes -o custom-columns=\
'NAME:.metadata.name,STATUS:.status.conditions[?(@.type=="Ready")].status,VERSION:.status.nodeInfo.kubeletVersion,CPU_CAP:.status.capacity.cpu,MEM_CAP:.status.capacity.memory' \
  --no-headers 2>/dev/null || echo "ERROR: Cannot reach cluster"

echo ""
echo "=== UNHEALTHY PODS ==="
# Pods not Running/Succeeded, with UTC start time instead of relative age
kubectl get pods --all-namespaces \
  --field-selector='status.phase!=Running,status.phase!=Succeeded' \
  -o custom-columns=\
'NAMESPACE:.metadata.namespace,POD:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount,STARTED_UTC:.status.startTime,NODE:.spec.nodeName' \
  --no-headers 2>/dev/null || true

# Also show pods that are Running but have containers not ready or high restarts
kubectl get pods --all-namespaces -o json 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except:
    sys.exit(0)
for pod in data.get('items', []):
    ns = pod['metadata']['namespace']
    name = pod['metadata']['name']
    node = pod['spec'].get('nodeName', 'N/A')
    start = pod['status'].get('startTime', 'N/A')
    phase = pod['status'].get('phase', 'Unknown')
    if phase != 'Running':
        continue
    for cs in pod['status'].get('containerStatuses', []):
        restarts = cs.get('restartCount', 0)
        ready = cs.get('ready', True)
        if restarts > 3 or not ready:
            reason = ''
            waiting = cs.get('state', {}).get('waiting', {})
            if waiting:
                reason = waiting.get('reason', '')
            print(f'{ns}\t{name}\t{phase}/NotReady\t{restarts}\t{start}\t{node}\t{reason}')
            break
" 2>/dev/null || true

echo ""
echo "=== RECENT EVENTS (last 2h, Warning/Error only) ==="
kubectl get events --all-namespaces \
  --field-selector='type!=Normal' \
  --sort-by='.lastTimestamp' \
  -o custom-columns=\
'NAMESPACE:.metadata.namespace,TYPE:.type,REASON:.reason,OBJECT:.involvedObject.name,LAST_SEEN_UTC:.lastTimestamp,MESSAGE:.message' \
  --no-headers 2>/dev/null | tail -50 || true

echo ""
echo "=== NAMESPACE TO STACK MAPPING ==="
# Parse terragrunt.hcl files to map k8s namespaces to stack directories
for tg in "$INFRA_DIR"/stacks/*/terragrunt.hcl; do
    stack_dir=$(dirname "$tg")
    stack_name=$(basename "$stack_dir")
    # Try to find namespace from the stack - check main.tf for namespace references
    ns=$(grep -h 'namespace' "$stack_dir"/main.tf 2>/dev/null | grep -oP '"\K[a-z0-9-]+(?=")' | head -1 || echo "$stack_name")
    echo "$ns → stacks/$stack_name"
done 2>/dev/null | sort -u || true

echo ""
echo "=== SERVICE TIERS ==="
# Parse service-catalog.md for tier classifications
catalog="$INFRA_DIR/.claude/reference/service-catalog.md"
if [ -f "$catalog" ]; then
    current_tier=""
    while IFS= read -r line; do
        case "$line" in
            *"Tier: core"*)  current_tier="core" ;;
            *"Tier: cluster"*) current_tier="cluster" ;;
            *"Admin"*)       current_tier="admin" ;;
            *"Active Use"*)  current_tier="active" ;;
            *"Optional"*|*"Inactive"*) current_tier="optional" ;;
        esac
        if [[ "$line" =~ ^\|[[:space:]]+([a-z0-9_-]+)[[:space:]]+\| && "$current_tier" != "" ]]; then
            svc="${BASH_REMATCH[1]}"
            [[ "$svc" == "Service" || "$svc" == "---" ]] && continue
            echo "$svc=$current_tier"
        fi
    done < "$catalog"
fi

echo ""
echo "=== CURRENT UTC TIME ==="
date -u '+%Y-%m-%dT%H:%M:%SZ'
