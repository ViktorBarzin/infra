#!/usr/bin/env bash
set -euo pipefail

KUBECTL="kubectl --kubeconfig /Users/viktorbarzin/code/infra/config"
DRY_RUN=false
AGENT="deploy-status"

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

# Check for stalled rollouts (Progressing=False or deadline exceeded)
check_stalled_rollouts() {
  if $DRY_RUN; then
    add_check "stalled-rollouts" "ok" "DRY RUN: would check for stalled deployment rollouts"
    return
  fi

  local stalled
  stalled=$($KUBECTL get deployments --all-namespaces -o json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
stalled = []
for dep in data.get('items', []):
  ns = dep['metadata']['namespace']
  name = dep['metadata']['name']
  conditions = dep.get('status', {}).get('conditions', [])
  for cond in conditions:
    if cond.get('type') == 'Progressing' and cond.get('status') == 'False':
      reason = cond.get('reason', 'unknown')
      stalled.append(f'{ns}/{name}: {reason}')
    elif cond.get('type') == 'Available' and cond.get('status') == 'False':
      reason = cond.get('reason', 'unknown')
      stalled.append(f'{ns}/{name}: unavailable ({reason})')
if stalled:
  print('; '.join(stalled))
else:
  print('')
" 2>/dev/null) || stalled="Failed to check deployments"

  if [ -z "$stalled" ]; then
    add_check "stalled-rollouts" "ok" "No stalled rollouts detected"
  else
    add_check "stalled-rollouts" "fail" "Stalled rollouts: $stalled"
  fi
}

# Check for unavailable replicas
check_unavailable_replicas() {
  if $DRY_RUN; then
    add_check "unavailable-replicas" "ok" "DRY RUN: would check for deployments with unavailable replicas"
    return
  fi

  local unavail
  unavail=$($KUBECTL get deployments --all-namespaces -o json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
issues = []
for dep in data.get('items', []):
  ns = dep['metadata']['namespace']
  name = dep['metadata']['name']
  spec_replicas = dep.get('spec', {}).get('replicas', 1)
  ready = dep.get('status', {}).get('readyReplicas', 0) or 0
  unavailable = dep.get('status', {}).get('unavailableReplicas', 0) or 0
  if unavailable > 0 or ready < spec_replicas:
    issues.append(f'{ns}/{name}: {ready}/{spec_replicas} ready, {unavailable} unavailable')
if issues:
  print('; '.join(issues))
else:
  print('')
" 2>/dev/null) || unavail="Failed to check replicas"

  if [ -z "$unavail" ]; then
    add_check "unavailable-replicas" "ok" "All deployments have desired replicas ready"
  else
    add_check "unavailable-replicas" "warn" "Unavailable replicas: $unavail"
  fi
}

# Check for image pull errors
check_image_pull_errors() {
  if $DRY_RUN; then
    add_check "image-pull-errors" "ok" "DRY RUN: would check for ImagePullBackOff/ErrImagePull pods"
    return
  fi

  local pull_errors
  pull_errors=$($KUBECTL get pods --all-namespaces -o json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
errors = []
for pod in data.get('items', []):
  ns = pod['metadata']['namespace']
  name = pod['metadata']['name']
  for cs in pod.get('status', {}).get('containerStatuses', []) + pod.get('status', {}).get('initContainerStatuses', []):
    waiting = cs.get('state', {}).get('waiting', {})
    reason = waiting.get('reason', '')
    if reason in ('ImagePullBackOff', 'ErrImagePull', 'InvalidImageName'):
      image = cs.get('image', 'unknown')
      msg = waiting.get('message', '')[:100]
      errors.append(f'{ns}/{name}: {reason} image={image} ({msg})')
if errors:
  print('; '.join(errors))
else:
  print('')
" 2>/dev/null) || pull_errors="Failed to check image pulls"

  if [ -z "$pull_errors" ]; then
    add_check "image-pull-errors" "ok" "No image pull errors found"
  else
    add_check "image-pull-errors" "fail" "Image pull errors: $pull_errors"
  fi
}

# Check for recent restarts (>5 in last hour)
check_recent_restarts() {
  if $DRY_RUN; then
    add_check "recent-restarts" "ok" "DRY RUN: would check for pods with high restart counts"
    return
  fi

  local restarts
  restarts=$($KUBECTL get pods --all-namespaces -o json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
high_restart = []
for pod in data.get('items', []):
  ns = pod['metadata']['namespace']
  name = pod['metadata']['name']
  for cs in pod.get('status', {}).get('containerStatuses', []):
    count = cs.get('restartCount', 0)
    if count >= 5:
      container = cs['name']
      high_restart.append(f'{ns}/{name}:{container} restarts={count}')
if high_restart:
  print('; '.join(sorted(high_restart, key=lambda x: int(x.split('=')[1]), reverse=True)[:20]))
else:
  print('')
" 2>/dev/null) || restarts="Failed to check restarts"

  if [ -z "$restarts" ]; then
    add_check "recent-restarts" "ok" "No pods with 5+ restarts"
  else
    add_check "recent-restarts" "warn" "High restart counts: $restarts"
  fi
}

# Check CrashLoopBackOff pods
check_crashloop() {
  if $DRY_RUN; then
    add_check "crashloop" "ok" "DRY RUN: would check for CrashLoopBackOff pods"
    return
  fi

  local crashloop
  crashloop=$($KUBECTL get pods --all-namespaces -o json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
crashes = []
for pod in data.get('items', []):
  ns = pod['metadata']['namespace']
  name = pod['metadata']['name']
  for cs in pod.get('status', {}).get('containerStatuses', []):
    waiting = cs.get('state', {}).get('waiting', {})
    if waiting.get('reason') == 'CrashLoopBackOff':
      container = cs['name']
      restarts = cs.get('restartCount', 0)
      crashes.append(f'{ns}/{name}:{container} restarts={restarts}')
if crashes:
  print('; '.join(crashes))
else:
  print('')
" 2>/dev/null) || crashloop="Failed to check crashloop"

  if [ -z "$crashloop" ]; then
    add_check "crashloop" "ok" "No CrashLoopBackOff pods"
  else
    add_check "crashloop" "fail" "CrashLoopBackOff: $crashloop"
  fi
}

# Run all checks
check_stalled_rollouts
check_unavailable_replicas
check_image_pull_errors
check_recent_restarts
check_crashloop

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
