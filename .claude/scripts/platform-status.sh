#!/usr/bin/env bash
set -euo pipefail

AGENT="platform-status"
KUBECTL="kubectl --kubeconfig /Users/viktorbarzin/code/infra/config"
PROXMOX_HOST="root@192.168.1.127"
REGISTRY_HOST="10.0.20.10"
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
  esac
done

checks=()

add_check() {
  local name="$1" status="$2" message="$3"
  checks+=("{\"name\": \"$name\", \"status\": \"$status\", \"message\": \"$message\"}")
}

check_traefik() {
  if $DRY_RUN; then
    add_check "traefik" "ok" "dry-run: would check Traefik status"
    return
  fi

  # Discover Traefik pods via labels
  local traefik_pod
  traefik_pod=$($KUBECTL get pods -n traefik -l app.kubernetes.io/name=traefik -o name 2>/dev/null | head -1)
  if [ -z "$traefik_pod" ]; then
    traefik_pod=$($KUBECTL get pods -n traefik -l app=traefik -o name 2>/dev/null | head -1)
  fi

  if [ -z "$traefik_pod" ]; then
    add_check "traefik" "fail" "No Traefik pods found in traefik namespace"
    return
  fi

  local phase
  phase=$($KUBECTL get "$traefik_pod" -n traefik -o jsonpath='{.status.phase}' 2>/dev/null)
  if [ "$phase" = "Running" ]; then
    # Check IngressRoute count
    local ir_count
    ir_count=$($KUBECTL get ingressroute --all-namespaces --no-headers 2>/dev/null | wc -l | tr -d ' ')
    add_check "traefik" "ok" "Traefik running, $ir_count IngressRoutes configured"
  else
    add_check "traefik" "fail" "Traefik pod phase: $phase"
  fi

  # Check for IngressRoutes with errors (TLS or service issues)
  local ir_errors
  ir_errors=$($KUBECTL get events --all-namespaces --field-selector reason=IngressRouteError --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [ "$ir_errors" -gt 0 ]; then
    add_check "traefik-ingressroutes" "warn" "$ir_errors IngressRoute error events found"
  fi
}

check_kyverno() {
  if $DRY_RUN; then
    add_check "kyverno" "ok" "dry-run: would check Kyverno status"
    return
  fi

  # Discover Kyverno pods via labels
  local kyverno_pods
  kyverno_pods=$($KUBECTL get pods -n kyverno -l app.kubernetes.io/name=kyverno -o name 2>/dev/null)
  if [ -z "$kyverno_pods" ]; then
    kyverno_pods=$($KUBECTL get pods -n kyverno -l app=kyverno -o name 2>/dev/null)
  fi

  if [ -z "$kyverno_pods" ]; then
    add_check "kyverno" "warn" "No Kyverno pods found"
    return
  fi

  local total=0 ready=0
  while IFS= read -r pod; do
    [ -z "$pod" ] && continue
    total=$((total + 1))
    local phase
    phase=$($KUBECTL get "$pod" -n kyverno -o jsonpath='{.status.phase}' 2>/dev/null)
    [ "$phase" = "Running" ] && ready=$((ready + 1))
  done <<< "$kyverno_pods"

  if [ "$ready" -eq "$total" ]; then
    # Check policy count
    local policy_count
    policy_count=$($KUBECTL get clusterpolicy --no-headers 2>/dev/null | wc -l | tr -d ' ')
    add_check "kyverno" "ok" "$ready/$total Kyverno pods running, $policy_count ClusterPolicies"
  else
    add_check "kyverno" "warn" "$ready/$total Kyverno pods running"
  fi

  # Check for policy violations
  local violations
  violations=$($KUBECTL get policyreport --all-namespaces -o json 2>/dev/null | \
    python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    fail_count = sum(r.get('summary',{}).get('fail',0) for r in data.get('items',[]))
    print(fail_count)
except: print('0')
" 2>/dev/null || echo "0")

  if [ "$violations" -gt 0 ]; then
    add_check "kyverno-violations" "warn" "$violations policy violations across namespaces"
  fi
}

check_vpa_goldilocks() {
  if $DRY_RUN; then
    add_check "vpa-goldilocks" "ok" "dry-run: would check VPA/Goldilocks status"
    return
  fi

  # Check VPA admission controller
  local vpa_pods
  vpa_pods=$($KUBECTL get pods -n goldilocks -l app.kubernetes.io/name=goldilocks -o name 2>/dev/null)
  if [ -z "$vpa_pods" ]; then
    vpa_pods=$($KUBECTL get pods -n goldilocks -o name 2>/dev/null)
  fi

  if [ -z "$vpa_pods" ]; then
    add_check "vpa-goldilocks" "warn" "No Goldilocks pods found"
    return
  fi

  local total=0 ready=0
  while IFS= read -r pod; do
    [ -z "$pod" ] && continue
    total=$((total + 1))
    local phase
    phase=$($KUBECTL get "$pod" -n goldilocks -o jsonpath='{.status.phase}' 2>/dev/null)
    [ "$phase" = "Running" ] && ready=$((ready + 1))
  done <<< "$vpa_pods"

  if [ "$ready" -eq "$total" ]; then
    local vpa_count
    vpa_count=$($KUBECTL get vpa --all-namespaces --no-headers 2>/dev/null | wc -l | tr -d ' ')
    add_check "vpa-goldilocks" "ok" "$ready/$total Goldilocks pods running, $vpa_count VPAs configured"
  else
    add_check "vpa-goldilocks" "warn" "$ready/$total Goldilocks pods running"
  fi

  # Check for VPAs with unexpected updateMode
  local auto_vpas
  auto_vpas=$($KUBECTL get vpa --all-namespaces -o json 2>/dev/null | \
    python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    auto = [i['metadata']['name'] for i in data.get('items',[]) if i.get('spec',{}).get('updatePolicy',{}).get('updateMode','') == 'Auto']
    print(len(auto))
except: print('0')
" 2>/dev/null || echo "0")

  if [ "$auto_vpas" -gt 0 ]; then
    add_check "vpa-auto-mode" "warn" "$auto_vpas VPAs set to Auto updateMode (may cause unexpected restarts)"
  fi
}

check_pull_through_cache() {
  if $DRY_RUN; then
    add_check "pull-through-cache" "ok" "dry-run: would check pull-through cache at $REGISTRY_HOST"
    return
  fi

  if timeout 5 curl -sf "http://${REGISTRY_HOST}:5000/v2/" &>/dev/null; then
    add_check "pull-through-cache" "ok" "Pull-through cache registry at $REGISTRY_HOST:5000 is healthy"
  elif timeout 5 curl -sf "https://${REGISTRY_HOST}/v2/" &>/dev/null; then
    add_check "pull-through-cache" "ok" "Pull-through cache registry at $REGISTRY_HOST is healthy (HTTPS)"
  else
    add_check "pull-through-cache" "fail" "Pull-through cache registry at $REGISTRY_HOST is unreachable"
  fi
}

check_proxmox() {
  if $DRY_RUN; then
    add_check "proxmox" "ok" "dry-run: would check Proxmox host resources"
    return
  fi

  local cpu_load
  if cpu_load=$(timeout 10 ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$PROXMOX_HOST" \
    "uptime | awk -F'load average:' '{print \$2}' | awk -F, '{print \$1}' | tr -d ' '" 2>/dev/null); then
    local cpu_count
    cpu_count=$(timeout 10 ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$PROXMOX_HOST" \
      "nproc" 2>/dev/null || echo "1")

    # Check memory
    local mem_info
    mem_info=$(timeout 10 ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$PROXMOX_HOST" \
      "free -m | awk '/Mem:/{printf \"%d/%dMB (%.0f%%)\", \$3, \$2, \$3/\$2*100}'" 2>/dev/null || echo "unknown")

    add_check "proxmox" "ok" "Proxmox host: load=$cpu_load (${cpu_count}cores), mem=$mem_info"
  else
    add_check "proxmox" "fail" "Could not reach Proxmox host via SSH"
  fi
}

check_metallb() {
  if $DRY_RUN; then
    add_check "metallb" "ok" "dry-run: would check MetalLB status"
    return
  fi

  local metallb_pods
  metallb_pods=$($KUBECTL get pods -n metallb-system -l app.kubernetes.io/name=metallb -o name 2>/dev/null)
  if [ -z "$metallb_pods" ]; then
    metallb_pods=$($KUBECTL get pods -n metallb-system -o name 2>/dev/null)
  fi

  if [ -z "$metallb_pods" ]; then
    add_check "metallb" "warn" "No MetalLB pods found"
    return
  fi

  local total=0 ready=0
  while IFS= read -r pod; do
    [ -z "$pod" ] && continue
    total=$((total + 1))
    local phase
    phase=$($KUBECTL get "$pod" -n metallb-system -o jsonpath='{.status.phase}' 2>/dev/null)
    [ "$phase" = "Running" ] && ready=$((ready + 1))
  done <<< "$metallb_pods"

  if [ "$ready" -eq "$total" ]; then
    add_check "metallb" "ok" "$ready/$total MetalLB pods running"
  else
    add_check "metallb" "warn" "$ready/$total MetalLB pods running"
  fi
}

# Run checks
check_traefik
check_kyverno
check_vpa_goldilocks
check_pull_through_cache
check_proxmox
check_metallb

# Determine overall status
overall="ok"
for c in "${checks[@]}"; do
  if echo "$c" | grep -q '"status": "fail"'; then
    overall="fail"
    break
  elif echo "$c" | grep -q '"status": "warn"'; then
    overall="warn"
  fi
done

# Output JSON
checks_json=$(IFS=,; echo "${checks[*]}")
cat <<EOF
{"status": "$overall", "agent": "$AGENT", "checks": [$checks_json]}
EOF
