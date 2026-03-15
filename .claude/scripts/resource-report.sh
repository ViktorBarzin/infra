#!/usr/bin/env bash
set -euo pipefail

KUBECTL="kubectl --kubeconfig /Users/viktorbarzin/code/infra/config"
DRY_RUN=false
AGENT="resource-report"

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
  esac
done

CHECKS="[]"

add_check() {
  local name="$1" status="$2" message="$3"
  CHECKS=$(echo "$CHECKS" | python3 -c "
import sys, json
checks = json.load(sys.stdin)
checks.append({'name': '''$name''', 'status': '''$status''', 'message': '''$message'''})
json.dump(checks, sys.stdout)
")
}

# Node capacity report: allocatable vs requests vs limits
check_node_capacity() {
  if $DRY_RUN; then
    add_check "node-capacity" "ok" "DRY RUN: would report node allocatable vs requests vs limits"
    return
  fi

  local report
  report=$($KUBECTL get nodes -o json | python3 -c "
import sys, json

def parse_cpu(val):
  if val.endswith('m'):
    return int(val[:-1])
  return int(float(val) * 1000)

def parse_mem(val):
  units = {'Ki': 1024, 'Mi': 1024**2, 'Gi': 1024**3, 'Ti': 1024**4}
  for suffix, mult in units.items():
    if val.endswith(suffix):
      return int(float(val[:-len(suffix)]) * mult)
  return int(val)

def fmt_mem(b):
  return f'{b / (1024**3):.1f}Gi'

def fmt_cpu(m):
  return f'{m}m'

data = json.load(sys.stdin)
nodes = []
for node in data.get('items', []):
  name = node['metadata']['name']
  alloc = node.get('status', {}).get('allocatable', {})
  cpu_alloc = parse_cpu(alloc.get('cpu', '0'))
  mem_alloc = parse_mem(alloc.get('memory', '0'))
  nodes.append({'name': name, 'cpu_alloc': cpu_alloc, 'mem_alloc': mem_alloc})

for n in nodes:
  print(f\"{n['name']}: cpu_alloc={fmt_cpu(n['cpu_alloc'])} mem_alloc={fmt_mem(n['mem_alloc'])}\")
" 2>/dev/null) || report="Failed to get node capacity"

  # Get requests/limits per node
  local usage
  usage=$($KUBECTL get pods --all-namespaces -o json | python3 -c "
import sys, json

def parse_cpu(val):
  if not val: return 0
  if val.endswith('m'):
    return int(val[:-1])
  return int(float(val) * 1000)

def parse_mem(val):
  if not val: return 0
  units = {'Ki': 1024, 'Mi': 1024**2, 'Gi': 1024**3, 'Ti': 1024**4}
  for suffix, mult in units.items():
    if val.endswith(suffix):
      return int(float(val[:-len(suffix)]) * mult)
  return int(val)

def fmt_mem(b):
  return f'{b / (1024**3):.1f}Gi'

def fmt_cpu(m):
  return f'{m}m'

data = json.load(sys.stdin)
per_node = {}
for pod in data.get('items', []):
  phase = pod.get('status', {}).get('phase', '')
  if phase not in ('Running', 'Pending'):
    continue
  node = pod.get('spec', {}).get('nodeName', 'unscheduled')
  if node not in per_node:
    per_node[node] = {'cpu_req': 0, 'cpu_lim': 0, 'mem_req': 0, 'mem_lim': 0}
  for c in pod.get('spec', {}).get('containers', []) + pod.get('spec', {}).get('initContainers', []):
    res = c.get('resources', {})
    per_node[node]['cpu_req'] += parse_cpu(res.get('requests', {}).get('cpu', ''))
    per_node[node]['cpu_lim'] += parse_cpu(res.get('limits', {}).get('cpu', ''))
    per_node[node]['mem_req'] += parse_mem(res.get('requests', {}).get('memory', ''))
    per_node[node]['mem_lim'] += parse_mem(res.get('limits', {}).get('memory', ''))

for node in sorted(per_node.keys()):
  n = per_node[node]
  print(f\"{node}: cpu_req={fmt_cpu(n['cpu_req'])} cpu_lim={fmt_cpu(n['cpu_lim'])} mem_req={fmt_mem(n['mem_req'])} mem_lim={fmt_mem(n['mem_lim'])}\")
" 2>/dev/null) || usage="Failed to get pod resource usage"

  add_check "node-capacity" "ok" "Allocatable: ${report} | Usage: ${usage}"
}

# Per-namespace ResourceQuota usage
check_resource_quotas() {
  if $DRY_RUN; then
    add_check "resource-quotas" "ok" "DRY RUN: would check ResourceQuota usage per namespace"
    return
  fi

  local quota_count
  quota_count=$($KUBECTL get resourcequota --all-namespaces --no-headers 2>/dev/null | wc -l | tr -d ' ') || quota_count=0

  if [ "$quota_count" -eq 0 ]; then
    add_check "resource-quotas" "ok" "No ResourceQuotas defined in the cluster"
    return
  fi

  local quota_report
  quota_report=$($KUBECTL get resourcequota --all-namespaces -o json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
results = []
for rq in data.get('items', []):
  ns = rq['metadata']['namespace']
  name = rq['metadata']['name']
  hard = rq.get('status', {}).get('hard', {})
  used = rq.get('status', {}).get('used', {})
  for resource in hard:
    h = hard[resource]
    u = used.get(resource, '0')
    results.append(f'{ns}/{name}: {resource} used={u} hard={h}')
if results:
  print('; '.join(results[:30]))
else:
  print('No quota usage data')
" 2>/dev/null) || quota_report="Failed to read ResourceQuotas"

  add_check "resource-quotas" "ok" "$quota_report"
}

# Top pods by memory usage
check_top_consumers() {
  if $DRY_RUN; then
    add_check "top-consumers" "ok" "DRY RUN: would report top memory-consuming pods"
    return
  fi

  local top_pods
  top_pods=$($KUBECTL top pods --all-namespaces --no-headers 2>/dev/null | sort -k4 -h -r | head -10 | awk '{print $1"/"$2": cpu="$3" mem="$4}' | tr '\n' '; ') || top_pods="metrics-server may not be available"

  if [ -z "$top_pods" ]; then
    add_check "top-consumers" "warn" "kubectl top returned no data — metrics-server may not be running"
  else
    add_check "top-consumers" "ok" "Top 10 by memory: ${top_pods}"
  fi
}

# Run all checks
check_node_capacity
check_resource_quotas
check_top_consumers

# Determine overall status
OVERALL=$(echo "$CHECKS" | python3 -c "
import sys, json
checks = json.load(sys.stdin)
statuses = [c['status'] for c in checks]
if 'fail' in statuses:
  print('fail')
elif 'warn' in statuses:
  print('warn')
else:
  print('ok')
")

echo "{\"status\": \"$OVERALL\", \"agent\": \"$AGENT\", \"checks\": $CHECKS}" | python3 -m json.tool
