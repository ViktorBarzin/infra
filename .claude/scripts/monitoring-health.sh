#!/usr/bin/env bash
set -euo pipefail

AGENT="monitoring-health"
KUBECTL="kubectl --kubeconfig /Users/viktorbarzin/code/infra/config"
MONITORING_NS="monitoring"
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

check_prometheus() {
  if $DRY_RUN; then
    add_check "prometheus" "ok" "dry-run: would check Prometheus server health"
    return
  fi

  # Discover Prometheus server pod via labels
  local prom_pod
  prom_pod=$($KUBECTL get pods -n "$MONITORING_NS" -l app.kubernetes.io/name=prometheus,app.kubernetes.io/component=server -o name 2>/dev/null | head -1)
  if [ -z "$prom_pod" ]; then
    prom_pod=$($KUBECTL get pods -n "$MONITORING_NS" -l app=prometheus,component=server -o name 2>/dev/null | head -1)
  fi
  if [ -z "$prom_pod" ]; then
    prom_pod=$($KUBECTL get pods -n "$MONITORING_NS" -o name 2>/dev/null | grep prometheus-server | head -1)
  fi

  if [ -z "$prom_pod" ]; then
    add_check "prometheus" "fail" "No Prometheus server pod found in $MONITORING_NS"
    return
  fi

  local phase
  phase=$($KUBECTL get "$prom_pod" -n "$MONITORING_NS" -o jsonpath='{.status.phase}' 2>/dev/null)
  if [ "$phase" != "Running" ]; then
    add_check "prometheus" "fail" "Prometheus server pod phase: $phase"
    return
  fi

  # Check Prometheus is responding
  local prom_healthy
  prom_healthy=$($KUBECTL exec "$prom_pod" -n "$MONITORING_NS" -c prometheus-server -- \
    wget -q -O- "http://localhost:9090/-/healthy" 2>/dev/null || echo "unhealthy")

  if echo "$prom_healthy" | grep -qi "ok\|healthy"; then
    # Check target scraping
    local targets_up
    targets_up=$($KUBECTL exec "$prom_pod" -n "$MONITORING_NS" -c prometheus-server -- \
      wget -q -O- "http://localhost:9090/api/v1/targets" 2>/dev/null | \
      python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    active = data.get('data',{}).get('activeTargets',[])
    up = sum(1 for t in active if t.get('health') == 'up')
    total = len(active)
    print(f'{up}/{total}')
except: print('unknown')
" 2>/dev/null || echo "unknown")
    add_check "prometheus" "ok" "Prometheus server healthy, targets: $targets_up up"
  else
    add_check "prometheus" "warn" "Prometheus server running but health check unclear"
  fi
}

check_alertmanager() {
  if $DRY_RUN; then
    add_check "alertmanager" "ok" "dry-run: would check Alertmanager health"
    return
  fi

  # Discover Alertmanager pod
  local am_pod
  am_pod=$($KUBECTL get pods -n "$MONITORING_NS" -l app.kubernetes.io/name=alertmanager -o name 2>/dev/null | head -1)
  if [ -z "$am_pod" ]; then
    am_pod=$($KUBECTL get pods -n "$MONITORING_NS" -o name 2>/dev/null | grep alertmanager | head -1)
  fi

  if [ -z "$am_pod" ]; then
    add_check "alertmanager" "fail" "No Alertmanager pod found in $MONITORING_NS"
    return
  fi

  local phase
  phase=$($KUBECTL get "$am_pod" -n "$MONITORING_NS" -o jsonpath='{.status.phase}' 2>/dev/null)
  if [ "$phase" != "Running" ]; then
    add_check "alertmanager" "fail" "Alertmanager pod phase: $phase"
    return
  fi

  # Check firing alerts
  local alert_info
  alert_info=$($KUBECTL exec "$am_pod" -n "$MONITORING_NS" -- \
    wget -q -O- "http://localhost:9093/api/v2/alerts?active=true" 2>/dev/null | \
    python3 -c "
import sys, json
try:
    alerts = json.load(sys.stdin)
    firing = [a for a in alerts if a.get('status',{}).get('state') == 'active']
    print(len(firing))
except: print('unknown')
" 2>/dev/null || echo "unknown")

  # Check silences
  local silence_count
  silence_count=$($KUBECTL exec "$am_pod" -n "$MONITORING_NS" -- \
    wget -q -O- "http://localhost:9093/api/v2/silences" 2>/dev/null | \
    python3 -c "
import sys, json
try:
    silences = json.load(sys.stdin)
    active = [s for s in silences if s.get('status',{}).get('state') == 'active']
    print(len(active))
except: print('0')
" 2>/dev/null || echo "0")

  if [ "$alert_info" = "unknown" ]; then
    add_check "alertmanager" "warn" "Alertmanager running but could not query alerts"
  else
    local status="ok"
    [ "$alert_info" -gt 0 ] 2>/dev/null && status="warn"
    add_check "alertmanager" "$status" "Alertmanager healthy: $alert_info firing alerts, $silence_count active silences"
  fi
}

check_grafana() {
  if $DRY_RUN; then
    add_check "grafana" "ok" "dry-run: would check Grafana health"
    return
  fi

  # Discover Grafana pod
  local grafana_pod
  grafana_pod=$($KUBECTL get pods -n "$MONITORING_NS" -l app.kubernetes.io/name=grafana -o name 2>/dev/null | head -1)
  if [ -z "$grafana_pod" ]; then
    grafana_pod=$($KUBECTL get pods -n "$MONITORING_NS" -o name 2>/dev/null | grep grafana | grep -v test | head -1)
  fi

  if [ -z "$grafana_pod" ]; then
    add_check "grafana" "fail" "No Grafana pod found in $MONITORING_NS"
    return
  fi

  local phase
  phase=$($KUBECTL get "$grafana_pod" -n "$MONITORING_NS" -o jsonpath='{.status.phase}' 2>/dev/null)
  if [ "$phase" != "Running" ]; then
    add_check "grafana" "fail" "Grafana pod phase: $phase"
    return
  fi

  # Check datasource connectivity
  local ds_info
  ds_info=$($KUBECTL exec "$grafana_pod" -n "$MONITORING_NS" -- \
    curl -sf "http://localhost:3000/api/datasources" 2>/dev/null | \
    python3 -c "
import sys, json
try:
    ds = json.load(sys.stdin)
    names = [d.get('name','?') for d in ds]
    print(f'{len(ds)} datasources: {\", \".join(names)}')
except: print('unknown')
" 2>/dev/null || echo "unknown")

  if [ "$ds_info" = "unknown" ]; then
    add_check "grafana" "warn" "Grafana running but could not query datasources (may need auth)"
  else
    add_check "grafana" "ok" "Grafana healthy, $ds_info"
  fi
}

check_snmp_exporters() {
  if $DRY_RUN; then
    add_check "snmp-exporters" "ok" "dry-run: would check SNMP exporter pods"
    return
  fi

  local exporters=("snmp-exporter" "idrac-redfish-exporter" "proxmox-exporter")
  local running=0 total=0

  for exporter in "${exporters[@]}"; do
    total=$((total + 1))
    local pod
    pod=$($KUBECTL get pods -n "$MONITORING_NS" -o name 2>/dev/null | grep "$exporter" | head -1)

    if [ -z "$pod" ]; then
      # Try all namespaces
      pod=$($KUBECTL get pods --all-namespaces -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name --no-headers 2>/dev/null | \
        grep "$exporter" | head -1)
      if [ -z "$pod" ]; then
        add_check "exporter-$exporter" "warn" "$exporter pod not found"
        continue
      fi
      local ns
      ns=$(echo "$pod" | awk '{print $1}')
      local name
      name=$(echo "$pod" | awk '{print $2}')
      local phase
      phase=$($KUBECTL get pod "$name" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)
      if [ "$phase" = "Running" ]; then
        running=$((running + 1))
        add_check "exporter-$exporter" "ok" "$exporter running in $ns"
      else
        add_check "exporter-$exporter" "warn" "$exporter phase: $phase in $ns"
      fi
    else
      local phase
      phase=$($KUBECTL get "$pod" -n "$MONITORING_NS" -o jsonpath='{.status.phase}' 2>/dev/null)
      if [ "$phase" = "Running" ]; then
        running=$((running + 1))
        add_check "exporter-$exporter" "ok" "$exporter running"
      else
        add_check "exporter-$exporter" "warn" "$exporter phase: $phase"
      fi
    fi
  done
}

check_prometheus_storage() {
  if $DRY_RUN; then
    add_check "prometheus-storage" "ok" "dry-run: would check Prometheus storage usage"
    return
  fi

  local prom_pvc
  prom_pvc=$($KUBECTL get pvc -n "$MONITORING_NS" -o name 2>/dev/null | grep prometheus-server | head -1)

  if [ -z "$prom_pvc" ]; then
    add_check "prometheus-storage" "warn" "No Prometheus server PVC found"
    return
  fi

  # Check storage via Prometheus TSDB stats
  local prom_pod
  prom_pod=$($KUBECTL get pods -n "$MONITORING_NS" -l app.kubernetes.io/name=prometheus,app.kubernetes.io/component=server -o name 2>/dev/null | head -1)
  if [ -z "$prom_pod" ]; then
    prom_pod=$($KUBECTL get pods -n "$MONITORING_NS" -o name 2>/dev/null | grep prometheus-server | head -1)
  fi

  if [ -n "$prom_pod" ]; then
    local storage_info
    storage_info=$($KUBECTL exec "$prom_pod" -n "$MONITORING_NS" -c prometheus-server -- \
      df -h /data 2>/dev/null | tail -1 | awk '{printf "%s used of %s (%s)", $3, $2, $5}' || echo "unknown")
    add_check "prometheus-storage" "ok" "Prometheus storage: $storage_info"
  else
    add_check "prometheus-storage" "warn" "Could not check Prometheus storage"
  fi
}

# Run checks
check_prometheus
check_alertmanager
check_grafana
check_snmp_exporters
check_prometheus_storage

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
