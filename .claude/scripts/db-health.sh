#!/usr/bin/env bash
set -euo pipefail

KUBECTL="kubectl --kubeconfig /Users/viktorbarzin/code/infra/config"
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

# MySQL InnoDB Cluster - Group Replication status
check_mysql_gr() {
  if $DRY_RUN; then
    add_check "mysql-group-replication" "ok" "DRY RUN: would check MySQL Group Replication status"
    return
  fi

  # Discover MySQL pod via labels first, fall back to known name
  local mysql_pod
  mysql_pod=$($KUBECTL get pods -n dbaas -l app=mysql-cluster -o name 2>/dev/null | head -1) || true
  if [ -z "$mysql_pod" ]; then
    mysql_pod=$($KUBECTL get pods -n dbaas -l app.kubernetes.io/name=mysql -o name 2>/dev/null | head -1) || true
  fi
  if [ -z "$mysql_pod" ]; then
    mysql_pod="sts/mysql-cluster"
  fi

  local gr_status
  gr_status=$($KUBECTL exec "$mysql_pod" -n dbaas -- mysql -N -e \
    "SELECT MEMBER_HOST, MEMBER_STATE, MEMBER_ROLE FROM performance_schema.replication_group_members" 2>/dev/null) || {
    add_check "mysql-group-replication" "fail" "Cannot connect to MySQL cluster to check GR status"
    return
  }

  local member_count online_count
  member_count=$(echo "$gr_status" | grep -c . || true)
  online_count=$(echo "$gr_status" | grep -c "ONLINE" || true)

  if [ "$online_count" -eq "$member_count" ] && [ "$member_count" -ge 3 ]; then
    add_check "mysql-group-replication" "ok" "All $member_count members ONLINE: $(echo "$gr_status" | tr '\t' ' ' | tr '\n' '; ')"
  elif [ "$online_count" -lt "$member_count" ]; then
    add_check "mysql-group-replication" "fail" "Only $online_count/$member_count members ONLINE: $(echo "$gr_status" | tr '\t' ' ' | tr '\n' '; ')"
  else
    add_check "mysql-group-replication" "warn" "Cluster has $member_count members (expected 3): $(echo "$gr_status" | tr '\t' ' ' | tr '\n' '; ')"
  fi
}

# MySQL pod health
check_mysql_pods() {
  if $DRY_RUN; then
    add_check "mysql-pods" "ok" "DRY RUN: would check MySQL pod status"
    return
  fi

  local pod_status
  pod_status=$($KUBECTL get pods -n dbaas -l app=mysql-cluster -o wide --no-headers 2>/dev/null) || \
  pod_status=$($KUBECTL get pods -n dbaas --no-headers 2>/dev/null | grep -i mysql) || {
    add_check "mysql-pods" "warn" "Cannot find MySQL pods in dbaas namespace"
    return
  }

  local not_running
  not_running=$(echo "$pod_status" | grep -v "Running" | grep -v "Completed" || true)

  if [ -z "$not_running" ]; then
    local count
    count=$(echo "$pod_status" | grep -c "Running" || true)
    add_check "mysql-pods" "ok" "$count MySQL pod(s) running in dbaas namespace"
  else
    add_check "mysql-pods" "fail" "Unhealthy MySQL pods: $(echo "$not_running" | awk '{print $1": "$3}' | tr '\n' '; ')"
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

  local mysql_pod
  mysql_pod=$($KUBECTL get pods -n dbaas -l app=mysql-cluster -o name 2>/dev/null | head -1) || true
  if [ -z "$mysql_pod" ]; then
    mysql_pod="sts/mysql-cluster"
  fi

  local conn_info
  conn_info=$($KUBECTL exec "$mysql_pod" -n dbaas -- mysql -N -e \
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
check_mysql_gr
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
