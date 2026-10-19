#!/usr/bin/env bash
set -euo pipefail

KUBECTL=${KUBECTL:-kubectl}
DRY_RUN=false
AGENT="db-health"

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

# MySQL runs as one StatefulSet pod. The active instance is mysql-v26 (MySQL
# 26.7, since 2026-10-15); mysql-standalone (8.4.8) is the rollback copy, kept
# at 0 replicas with its PVC. local.mysql_active in stacks/dbaas names the
# active one.
MYSQL_STS="mysql-v26"

mysql_query() {
  $KUBECTL exec -n dbaas "$MYSQL_STS-0" -c mysql -- \
    sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot -N -e "$1"' sh "$1"
}

# Active MySQL answers and accepts writes
check_mysql_active() {
  if $DRY_RUN; then
    add_check "mysql-active" "ok" "DRY RUN: would check $MYSQL_STS answers and is writable"
    return
  fi

  local info
  info=$(mysql_query "SELECT @@version, @@super_read_only, @@read_only" 2>/dev/null) || {
    add_check "mysql-active" "fail" "Cannot connect to $MYSQL_STS-0"
    return
  }

  local version sro ro
  read -r version sro ro <<<"$info"
  if [ "$sro" = "0" ] && [ "$ro" = "0" ]; then
    add_check "mysql-active" "ok" "$MYSQL_STS-0 MySQL $version, writable"
  else
    add_check "mysql-active" "fail" "$MYSQL_STS-0 MySQL $version is read-only (super_read_only=$sro read_only=$ro)"
  fi
}

# MySQL pod health
check_mysql_pods() {
  if $DRY_RUN; then
    add_check "mysql-pods" "ok" "DRY RUN: would check MySQL pod status"
    return
  fi

  local pod_status
  pod_status=$($KUBECTL get pods -n dbaas -l "app.kubernetes.io/instance=$MYSQL_STS" --no-headers 2>/dev/null) || true
  if [ -z "$pod_status" ]; then
    add_check "mysql-pods" "fail" "No $MYSQL_STS pod in dbaas namespace"
    return
  fi

  local not_ready
  not_ready=$(echo "$pod_status" | awk '{split($2, r, "/")} $3 != "Running" || r[1] != r[2]' || true)

  if [ -z "$not_ready" ]; then
    add_check "mysql-pods" "ok" "$MYSQL_STS: $(echo "$pod_status" | awk '{print $1" "$2" "$3}' | tr '\n' ' ')"
  else
    add_check "mysql-pods" "fail" "Unhealthy MySQL pods: $(echo "$not_ready" | awk '{print $1": "$2" "$3}' | tr '\n' '; ')"
  fi
}

# CNPG PostgreSQL cluster health
check_cnpg() {
  if $DRY_RUN; then
    add_check "cnpg-clusters" "ok" "DRY RUN: would check CNPG PostgreSQL cluster health"
    return
  fi

  # Check if CNPG CRDs exist
  local cnpg_clusters
  cnpg_clusters=$($KUBECTL get cluster.postgresql.cnpg.io --all-namespaces -o json 2>/dev/null) || {
    add_check "cnpg-clusters" "warn" "CNPG CRD not found or no clusters deployed"
    return
  }

  local report
  report=$(echo "$cnpg_clusters" | python3 -c "
import sys, json
data = json.load(sys.stdin)
results = []
all_healthy = True
for cluster in data.get('items', []):
  ns = cluster['metadata']['namespace']
  name = cluster['metadata']['name']
  phase = cluster.get('status', {}).get('phase', 'unknown')
  ready = cluster.get('status', {}).get('readyInstances', 0)
  instances = cluster.get('spec', {}).get('instances', 0)
  primary = cluster.get('status', {}).get('currentPrimary', 'unknown')
  # A hibernated cluster (pg-cluster, the PG16 rollback copy) has no pods by design.
  if cluster['metadata'].get('annotations', {}).get('cnpg.io/hibernation') == 'on':
    results.append(f'{ns}/{name}: hibernated')
    continue
  if phase != 'Cluster in healthy state' and phase != 'Healthy':
    all_healthy = False
  if ready < instances:
    all_healthy = False
  results.append(f'{ns}/{name}: phase={phase} ready={ready}/{instances} primary={primary}')
print('HEALTHY' if all_healthy else 'UNHEALTHY')
print('; '.join(results))
" 2>/dev/null) || report="Failed to parse CNPG status"

  local health_line
  health_line=$(echo "$report" | head -1)
  local detail_line
  detail_line=$(echo "$report" | tail -1)

  if [ "$health_line" = "HEALTHY" ]; then
    add_check "cnpg-clusters" "ok" "$detail_line"
  else
    add_check "cnpg-clusters" "fail" "$detail_line"
  fi
}

# Database connection counts (MySQL)
check_mysql_connections() {
  if $DRY_RUN; then
    add_check "mysql-connections" "ok" "DRY RUN: would check MySQL connection counts"
    return
  fi

  local conn_info
  conn_info=$(mysql_query \
    "SELECT 'threads_connected', VARIABLE_VALUE FROM performance_schema.global_status WHERE VARIABLE_NAME='Threads_connected' UNION ALL SELECT 'max_connections', VARIABLE_VALUE FROM performance_schema.global_variables WHERE VARIABLE_NAME='max_connections'" 2>/dev/null) || {
    add_check "mysql-connections" "warn" "Cannot query MySQL connection info"
    return
  }

  local threads_connected max_connections
  threads_connected=$(echo "$conn_info" | grep threads_connected | awk '{print $2}') || threads_connected="unknown"
  max_connections=$(echo "$conn_info" | grep max_connections | awk '{print $2}') || max_connections="unknown"

  if [ "$threads_connected" != "unknown" ] && [ "$max_connections" != "unknown" ]; then
    local pct=$((threads_connected * 100 / max_connections))
    if [ "$pct" -gt 80 ]; then
      add_check "mysql-connections" "fail" "MySQL connections at ${pct}%: $threads_connected/$max_connections"
    elif [ "$pct" -gt 60 ]; then
      add_check "mysql-connections" "warn" "MySQL connections at ${pct}%: $threads_connected/$max_connections"
    else
      add_check "mysql-connections" "ok" "MySQL connections: $threads_connected/$max_connections (${pct}%)"
    fi
  else
    add_check "mysql-connections" "warn" "MySQL connections: threads=$threads_connected max=$max_connections"
  fi
}

# Run all checks
check_mysql_active
check_mysql_pods
check_cnpg
check_mysql_connections

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
