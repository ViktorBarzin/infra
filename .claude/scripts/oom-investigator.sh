#!/usr/bin/env bash
set -euo pipefail

KUBECTL="kubectl --kubeconfig /Users/viktorbarzin/code/infra/config"
DRY_RUN=false
AGENT="oom-investigator"

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

# Find OOMKilled pods across all namespaces
find_oomkilled() {
  if $DRY_RUN; then
    add_check "oom-killed-pods" "ok" "DRY RUN: would check for OOMKilled pods across all namespaces"
    return
  fi

  local oom_pods
  oom_pods=$($KUBECTL get pods --all-namespaces -o json | python3 -c "
import sys, json
data = json.load(sys.stdin)
results = []
for pod in data.get('items', []):
  ns = pod['metadata']['namespace']
  name = pod['metadata']['name']
  for cs in pod.get('status', {}).get('containerStatuses', []) + pod.get('status', {}).get('initContainerStatuses', []):
    last = cs.get('lastState', {}).get('terminated', {})
    current = cs.get('state', {}).get('terminated', {})
    for state in [last, current]:
      if state.get('reason') == 'OOMKilled':
        container = cs['name']
        restart_count = cs.get('restartCount', 0)
        finished = state.get('finishedAt', 'unknown')
        results.append({'namespace': ns, 'pod': name, 'container': container, 'restarts': restart_count, 'finishedAt': finished})
json.dump(results, sys.stdout)
" 2>/dev/null) || oom_pods="[]"

  local count
  count=$(echo "$oom_pods" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")

  if [ "$count" -eq 0 ]; then
    add_check "oom-killed-pods" "ok" "No OOMKilled pods found"
  else
    add_check "oom-killed-pods" "fail" "Found $count OOMKilled container(s): $(echo "$oom_pods" | python3 -c "
import sys,json
pods = json.load(sys.stdin)
print('; '.join(f\"{p['namespace']}/{p['pod']}:{p['container']} (restarts={p['restarts']}, at={p['finishedAt']})\" for p in pods))
")"
  fi
}

# Check LimitRange defaults in namespaces with OOM events
check_limitranges() {
  if $DRY_RUN; then
    add_check "limitranges" "ok" "DRY RUN: would check LimitRange defaults"
    return
  fi

  local namespaces
  namespaces=$($KUBECTL get pods --all-namespaces -o json | python3 -c "
import sys, json
data = json.load(sys.stdin)
ns_set = set()
for pod in data.get('items', []):
  for cs in pod.get('status', {}).get('containerStatuses', []) + pod.get('status', {}).get('initContainerStatuses', []):
    for state in [cs.get('lastState', {}).get('terminated', {}), cs.get('state', {}).get('terminated', {})]:
      if state.get('reason') == 'OOMKilled':
        ns_set.add(pod['metadata']['namespace'])
for ns in sorted(ns_set):
  print(ns)
" 2>/dev/null) || namespaces=""

  if [ -z "$namespaces" ]; then
    add_check "limitranges" "ok" "No namespaces with OOMKilled pods to check"
    return
  fi

  local lr_info=""
  while IFS= read -r ns; do
    local lr
    lr=$($KUBECTL get limitrange -n "$ns" -o json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('items', []):
  for limit in item.get('spec', {}).get('limits', []):
    if limit.get('type') == 'Container':
      default_mem = limit.get('default', {}).get('memory', 'none')
      default_cpu = limit.get('default', {}).get('cpu', 'none')
      print(f'$ns: default memory={default_mem}, cpu={default_cpu}')
" 2>/dev/null) || lr=""
    if [ -n "$lr" ]; then
      lr_info="${lr_info}${lr}; "
    else
      lr_info="${lr_info}${ns}: no LimitRange; "
    fi
  done <<< "$namespaces"

  add_check "limitranges" "warn" "LimitRange defaults for OOM namespaces: ${lr_info}"
}

# Check VPA recommendations from Goldilocks
check_vpa_recommendations() {
  if $DRY_RUN; then
    add_check "vpa-recommendations" "ok" "DRY RUN: would check VPA recommendations"
    return
  fi

  local vpa_count
  vpa_count=$($KUBECTL get vpa --all-namespaces --no-headers 2>/dev/null | wc -l | tr -d ' ') || vpa_count=0

  if [ "$vpa_count" -eq 0 ]; then
    add_check "vpa-recommendations" "warn" "No VPA objects found — Goldilocks may not be deployed"
    return
  fi

  local vpa_recs
  vpa_recs=$($KUBECTL get vpa --all-namespaces -o json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
recs = []
for vpa in data.get('items', []):
  ns = vpa['metadata']['namespace']
  name = vpa['metadata']['name']
  for cr in vpa.get('status', {}).get('recommendation', {}).get('containerRecommendations', []):
    container = cr.get('containerName', 'unknown')
    target_mem = cr.get('target', {}).get('memory', 'n/a')
    target_cpu = cr.get('target', {}).get('cpu', 'n/a')
    upper_mem = cr.get('upperBound', {}).get('memory', 'n/a')
    recs.append(f'{ns}/{name}:{container} target_mem={target_mem} target_cpu={target_cpu} upper_mem={upper_mem}')
if recs:
  print('; '.join(recs[:20]))
else:
  print('No recommendations available yet')
" 2>/dev/null) || vpa_recs="Failed to read VPA recommendations"

  add_check "vpa-recommendations" "ok" "$vpa_recs"
}

# Check resource requests/limits on OOMKilled pods
check_pod_resources() {
  if $DRY_RUN; then
    add_check "pod-resources" "ok" "DRY RUN: would check pod resource specs"
    return
  fi

  local resources
  resources=$($KUBECTL get pods --all-namespaces -o json | python3 -c "
import sys, json
data = json.load(sys.stdin)
results = []
for pod in data.get('items', []):
  ns = pod['metadata']['namespace']
  name = pod['metadata']['name']
  has_oom = False
  for cs in pod.get('status', {}).get('containerStatuses', []) + pod.get('status', {}).get('initContainerStatuses', []):
    for state in [cs.get('lastState', {}).get('terminated', {}), cs.get('state', {}).get('terminated', {})]:
      if state.get('reason') == 'OOMKilled':
        has_oom = True
        break
  if has_oom:
    for c in pod.get('spec', {}).get('containers', []) + pod.get('spec', {}).get('initContainers', []):
      req_mem = c.get('resources', {}).get('requests', {}).get('memory', 'none')
      lim_mem = c.get('resources', {}).get('limits', {}).get('memory', 'none')
      req_cpu = c.get('resources', {}).get('requests', {}).get('cpu', 'none')
      lim_cpu = c.get('resources', {}).get('limits', {}).get('cpu', 'none')
      results.append(f\"{ns}/{name}:{c['name']} req_mem={req_mem} lim_mem={lim_mem} req_cpu={req_cpu} lim_cpu={lim_cpu}\")
if results:
  print('; '.join(results))
else:
  print('No OOMKilled pods to inspect')
" 2>/dev/null) || resources="Failed to check pod resources"

  if echo "$resources" | grep -q "No OOMKilled"; then
    add_check "pod-resources" "ok" "$resources"
  else
    add_check "pod-resources" "warn" "$resources"
  fi
}

# Run all checks
find_oomkilled
check_limitranges
check_vpa_recommendations
check_pod_resources

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
