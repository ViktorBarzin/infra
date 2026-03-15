#!/usr/bin/env bash
set -euo pipefail

KUBECTL="kubectl --kubeconfig /Users/viktorbarzin/code/infra/config"
AGENT="crowdsec-status"
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

find_crowdsec_namespace() {
  $KUBECTL get pods -A -l app.kubernetes.io/name=crowdsec --no-headers 2>/dev/null | head -1 | awk '{print $1}' || \
  $KUBECTL get pods -A --no-headers 2>/dev/null | grep -i crowdsec | head -1 | awk '{print $1}' || \
  echo "crowdsec"
}

check_lapi_health() {
  if $DRY_RUN; then
    add_check "crowdsec-lapi" "ok" "dry-run: would check CrowdSec LAPI pod health"
    return
  fi

  local ns
  ns=$(find_crowdsec_namespace)

  local lapi_pod
  lapi_pod=$($KUBECTL get pods -n "$ns" -l app.kubernetes.io/name=crowdsec,app.kubernetes.io/component=lapi --no-headers 2>/dev/null | head -1) || true

  if [ -z "$lapi_pod" ]; then
    lapi_pod=$($KUBECTL get pods -n "$ns" --no-headers 2>/dev/null | grep -i "crowdsec.*lapi" | head -1) || true
  fi

  if [ -z "$lapi_pod" ]; then
    add_check "crowdsec-lapi" "fail" "No CrowdSec LAPI pod found in namespace ${ns}"
    return
  fi

  local pod_name status
  pod_name=$(echo "$lapi_pod" | awk '{print $1}')
  status=$(echo "$lapi_pod" | awk '{print $3}')

  if [ "$status" != "Running" ]; then
    add_check "crowdsec-lapi" "fail" "LAPI pod ${pod_name} is ${status}"
    return
  fi

  add_check "crowdsec-lapi" "ok" "LAPI pod ${pod_name} is Running"
}

check_cscli_metrics() {
  if $DRY_RUN; then
    add_check "crowdsec-metrics" "ok" "dry-run: would run cscli metrics via kubectl exec"
    return
  fi

  local ns
  ns=$(find_crowdsec_namespace)

  local lapi_pod
  lapi_pod=$($KUBECTL get pods -n "$ns" -l app.kubernetes.io/name=crowdsec,app.kubernetes.io/component=lapi -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || \
  lapi_pod=$($KUBECTL get pods -n "$ns" --no-headers 2>/dev/null | grep -i "crowdsec.*lapi" | head -1 | awk '{print $1}') || true

  if [ -z "$lapi_pod" ]; then
    add_check "crowdsec-metrics" "warn" "No LAPI pod found to run cscli metrics"
    return
  fi

  local metrics_output
  metrics_output=$($KUBECTL exec -n "$ns" "$lapi_pod" -- cscli metrics 2>/dev/null) || {
    add_check "crowdsec-metrics" "warn" "Failed to run cscli metrics on ${lapi_pod}"
    return
  }

  add_check "crowdsec-metrics" "ok" "cscli metrics returned successfully"
}

check_decisions() {
  if $DRY_RUN; then
    add_check "crowdsec-decisions" "ok" "dry-run: would check cscli decisions list"
    return
  fi

  local ns
  ns=$(find_crowdsec_namespace)

  local lapi_pod
  lapi_pod=$($KUBECTL get pods -n "$ns" -l app.kubernetes.io/name=crowdsec,app.kubernetes.io/component=lapi -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) || \
  lapi_pod=$($KUBECTL get pods -n "$ns" --no-headers 2>/dev/null | grep -i "crowdsec.*lapi" | head -1 | awk '{print $1}') || true

  if [ -z "$lapi_pod" ]; then
    add_check "crowdsec-decisions" "warn" "No LAPI pod found to check decisions"
    return
  fi

  local decisions
  decisions=$($KUBECTL exec -n "$ns" "$lapi_pod" -- cscli decisions list -o json 2>/dev/null) || {
    add_check "crowdsec-decisions" "ok" "No active decisions (or failed to query)"
    return
  }

  local count
  count=$(echo "$decisions" | jq 'if type == "array" then length else 0 end' 2>/dev/null || echo "0")

  if [ "$count" -gt 0 ]; then
    add_check "crowdsec-decisions" "ok" "${count} active decision(s)"
  else
    add_check "crowdsec-decisions" "ok" "No active decisions"
  fi
}

check_agent_daemonset() {
  if $DRY_RUN; then
    add_check "crowdsec-agents" "ok" "dry-run: would check CrowdSec agent DaemonSet"
    return
  fi

  local ns
  ns=$(find_crowdsec_namespace)

  local ds_json
  ds_json=$($KUBECTL get daemonset -n "$ns" -l app.kubernetes.io/name=crowdsec -o json 2>/dev/null) || {
    # Fallback: search by name
    ds_json=$($KUBECTL get daemonset -n "$ns" -o json 2>/dev/null | jq '{items: [.items[] | select(.metadata.name | test("crowdsec"))]}') || {
      add_check "crowdsec-agents" "warn" "No CrowdSec DaemonSet found"
      return
    }
  }

  local desired ready
  desired=$(echo "$ds_json" | jq '[.items[].status.desiredNumberScheduled] | add // 0' 2>/dev/null || echo "0")
  ready=$(echo "$ds_json" | jq '[.items[].status.numberReady] | add // 0' 2>/dev/null || echo "0")

  if [ "$ready" -lt "$desired" ]; then
    add_check "crowdsec-agents" "warn" "CrowdSec agents: ${ready}/${desired} ready"
  elif [ "$desired" -eq 0 ]; then
    add_check "crowdsec-agents" "warn" "No CrowdSec agent DaemonSet pods scheduled"
  else
    add_check "crowdsec-agents" "ok" "CrowdSec agents: ${ready}/${desired} ready"
  fi
}

check_lapi_health
check_cscli_metrics
check_decisions
check_agent_daemonset

# Output JSON
overall="ok"
for c in "${checks[@]}"; do
  s=$(echo "$c" | jq -r '.status')
  if [ "$s" = "fail" ]; then overall="fail"; break; fi
  if [ "$s" = "warn" ]; then overall="warn"; fi
done

printf '{"status": "%s", "agent": "%s", "checks": [%s]}\n' \
  "$overall" "$AGENT" "$(IFS=,; echo "${checks[*]}")"
