#!/usr/bin/env bash
set -euo pipefail

KUBECTL="kubectl --kubeconfig /Users/viktorbarzin/code/infra/config"
PFSENSE="python3 /Users/viktorbarzin/code/infra/.claude/pfsense.py"
AGENT="network-health"
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

check_pfsense_status() {
  if $DRY_RUN; then
    add_check "pfsense" "ok" "dry-run: would check pfSense system status via pfsense.py"
    return
  fi

  local pf_output
  pf_output=$($PFSENSE status 2>/dev/null) || {
    add_check "pfsense" "fail" "Failed to connect to pfSense via pfsense.py"
    return
  }

  if echo "$pf_output" | grep -qi "error\|fail\|down"; then
    add_check "pfsense" "warn" "pfSense reported issues: $(echo "$pf_output" | head -3 | tr '\n' ' ')"
  else
    add_check "pfsense" "ok" "pfSense system healthy"
  fi
}

check_vpn_status() {
  if $DRY_RUN; then
    add_check "vpn" "ok" "dry-run: would check VPN tunnel status via pfsense.py"
    return
  fi

  local vpn_output
  vpn_output=$($PFSENSE wireguard 2>/dev/null) || {
    add_check "vpn" "warn" "Failed to query VPN status via pfsense.py"
    return
  }

  if echo "$vpn_output" | grep -qi "error\|fail\|down"; then
    add_check "vpn" "warn" "VPN issues detected: $(echo "$vpn_output" | head -3 | tr '\n' ' ')"
  else
    add_check "vpn" "ok" "VPN tunnels healthy"
  fi
}

check_metallb_speakers() {
  if $DRY_RUN; then
    add_check "metallb-speakers" "ok" "dry-run: would check MetalLB speaker pod health"
    return
  fi

  local ns="metallb-system"

  # Find MetalLB speaker pods via labels first
  local speaker_pods
  speaker_pods=$($KUBECTL get pods -n "$ns" -l app.kubernetes.io/component=speaker --no-headers 2>/dev/null) || \
  speaker_pods=$($KUBECTL get pods -n "$ns" -l component=speaker --no-headers 2>/dev/null) || \
  speaker_pods=$($KUBECTL get pods -n "$ns" --no-headers 2>/dev/null | grep -i speaker || true)

  if [ -z "$speaker_pods" ]; then
    add_check "metallb-speakers" "warn" "No MetalLB speaker pods found in ${ns}"
    return
  fi

  local total not_running
  total=$(echo "$speaker_pods" | grep -c "." 2>/dev/null || echo "0")
  not_running=$(echo "$speaker_pods" | grep -v "Running" | grep -c "." 2>/dev/null || echo "0")

  if [ "$not_running" -gt 0 ]; then
    add_check "metallb-speakers" "fail" "${not_running}/${total} MetalLB speaker pod(s) not running"
  else
    add_check "metallb-speakers" "ok" "All ${total} MetalLB speaker pod(s) running"
  fi
}

check_metallb_l2() {
  if $DRY_RUN; then
    add_check "metallb-l2" "ok" "dry-run: would check MetalLB L2 advertisements"
    return
  fi

  local ns="metallb-system"

  # Check L2Advertisement CRDs
  local l2_ads
  l2_ads=$($KUBECTL get l2advertisements -n "$ns" -o json 2>/dev/null) || {
    add_check "metallb-l2" "warn" "Could not query L2Advertisement CRDs"
    return
  }

  local count
  count=$(echo "$l2_ads" | jq '.items | length' 2>/dev/null || echo "0")

  if [ "$count" -eq 0 ]; then
    add_check "metallb-l2" "warn" "No L2Advertisement resources found"
  else
    # Check MetalLB controller
    local controller
    controller=$($KUBECTL get pods -n "$ns" -l app.kubernetes.io/component=controller --no-headers 2>/dev/null) || \
    controller=$($KUBECTL get pods -n "$ns" --no-headers 2>/dev/null | grep -i controller || true)

    if [ -z "$controller" ]; then
      add_check "metallb-l2" "warn" "${count} L2Advertisement(s) found but no controller pod"
    elif echo "$controller" | grep -q "Running"; then
      add_check "metallb-l2" "ok" "${count} L2Advertisement(s) configured, controller running"
    else
      add_check "metallb-l2" "warn" "${count} L2Advertisement(s) found but controller not running"
    fi
  fi
}

check_node_connectivity() {
  if $DRY_RUN; then
    add_check "node-connectivity" "ok" "dry-run: would ping k8s nodes"
    return
  fi

  local nodes=("10.0.20.100" "10.0.20.101" "10.0.20.102" "10.0.20.103" "10.0.20.104")
  local names=("k8s-master" "k8s-node1" "k8s-node2" "k8s-node3" "k8s-node4")
  local failures=0
  local failure_details=""

  for i in "${!nodes[@]}"; do
    if ! ping -c 1 -W 2 "${nodes[$i]}" >/dev/null 2>&1; then
      failures=$((failures + 1))
      failure_details="${failure_details}${names[$i]}(${nodes[$i]}) "
    fi
  done

  if [ "$failures" -gt 0 ]; then
    add_check "node-connectivity" "fail" "${failures} node(s) unreachable: ${failure_details}"
  else
    add_check "node-connectivity" "ok" "All ${#nodes[@]} nodes reachable"
  fi
}

check_pfsense_status
check_vpn_status
check_metallb_speakers
check_metallb_l2
check_node_connectivity

# Output JSON
overall="ok"
for c in "${checks[@]}"; do
  s=$(echo "$c" | jq -r '.status')
  if [ "$s" = "fail" ]; then overall="fail"; break; fi
  if [ "$s" = "warn" ]; then overall="warn"; fi
done

printf '{"status": "%s", "agent": "%s", "checks": [%s]}\n' \
  "$overall" "$AGENT" "$(IFS=,; echo "${checks[*]}")"
