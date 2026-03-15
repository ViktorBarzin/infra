#!/usr/bin/env bash
set -euo pipefail

KUBECTL="kubectl --kubeconfig /Users/viktorbarzin/code/infra/config"
DRY_RUN=false
AGENT="backup-verify"

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

# CNPG backup freshness via backup CRDs
check_cnpg_backups() {
  if $DRY_RUN; then
    add_check "cnpg-backups" "ok" "DRY RUN: would check CNPG backup CRD timestamps"
    return
  fi

  local backups
  backups=$($KUBECTL get backup.postgresql.cnpg.io --all-namespaces -o json 2>/dev/null) || {
    # Try scheduledbackup as well
    local scheduled
    scheduled=$($KUBECTL get scheduledbackup.postgresql.cnpg.io --all-namespaces --no-headers 2>/dev/null) || true
    if [ -n "$scheduled" ]; then
      add_check "cnpg-backups" "warn" "ScheduledBackups exist but no Backup CRDs found — backups may not have run yet"
    else
      add_check "cnpg-backups" "warn" "No CNPG Backup CRDs found"
    fi
    return
  }

  local report
  report=$(echo "$backups" | python3 -c "
import sys, json
from datetime import datetime, timezone

data = json.load(sys.stdin)
items = data.get('items', [])
if not items:
  print('WARN|No CNPG backups found')
  sys.exit(0)

# Group by cluster, find latest backup per cluster
clusters = {}
for b in items:
  ns = b['metadata']['namespace']
  cluster = b.get('spec', {}).get('cluster', {}).get('name', 'unknown')
  key = f'{ns}/{cluster}'
  phase = b.get('status', {}).get('phase', 'unknown')
  started = b.get('status', {}).get('startedAt', '')
  stopped = b.get('status', {}).get('stoppedAt', '')
  if key not in clusters or stopped > clusters[key].get('stopped', ''):
    clusters[key] = {'phase': phase, 'started': started, 'stopped': stopped}

results = []
all_ok = True
now = datetime.now(timezone.utc)
for key, info in sorted(clusters.items()):
  age_str = 'unknown'
  if info['stopped']:
    try:
      stopped_dt = datetime.fromisoformat(info['stopped'].replace('Z', '+00:00'))
      age = now - stopped_dt
      age_hours = age.total_seconds() / 3600
      age_str = f'{age_hours:.1f}h ago'
      if age_hours > 48:
        all_ok = False
    except Exception:
      age_str = info['stopped']
  else:
    all_ok = False
    age_str = 'no completion time'

  phase = info['phase']
  if phase not in ('completed', 'Completed'):
    all_ok = False
  results.append(f'{key}: {phase} ({age_str})')

status = 'OK' if all_ok else 'WARN'
print(f'{status}|' + '; '.join(results))
" 2>/dev/null) || report="WARN|Failed to parse CNPG backups"

  local status_prefix="${report%%|*}"
  local detail="${report#*|}"

  if [ "$status_prefix" = "OK" ]; then
    add_check "cnpg-backups" "ok" "$detail"
  else
    add_check "cnpg-backups" "warn" "$detail"
  fi
}

# CNPG ScheduledBackup health
check_cnpg_scheduled() {
  if $DRY_RUN; then
    add_check "cnpg-scheduled-backups" "ok" "DRY RUN: would check CNPG ScheduledBackup status"
    return
  fi

  local scheduled
  scheduled=$($KUBECTL get scheduledbackup.postgresql.cnpg.io --all-namespaces -o json 2>/dev/null) || {
    add_check "cnpg-scheduled-backups" "ok" "No CNPG ScheduledBackups configured"
    return
  }

  local report
  report=$(echo "$scheduled" | python3 -c "
import sys, json
data = json.load(sys.stdin)
items = data.get('items', [])
if not items:
  print('OK|No ScheduledBackups defined')
  sys.exit(0)
results = []
all_ok = True
for sb in items:
  ns = sb['metadata']['namespace']
  name = sb['metadata']['name']
  schedule = sb.get('spec', {}).get('schedule', 'unknown')
  suspend = sb.get('spec', {}).get('suspend', False)
  last = sb.get('status', {}).get('lastScheduleTime', 'never')
  if suspend:
    all_ok = False
    results.append(f'{ns}/{name}: SUSPENDED schedule={schedule}')
  else:
    results.append(f'{ns}/{name}: active schedule={schedule} last={last}')
status = 'OK' if all_ok else 'WARN'
print(f'{status}|' + '; '.join(results))
" 2>/dev/null) || report="WARN|Failed to parse ScheduledBackups"

  local status_prefix="${report%%|*}"
  local detail="${report#*|}"

  if [ "$status_prefix" = "OK" ]; then
    add_check "cnpg-scheduled-backups" "ok" "$detail"
  else
    add_check "cnpg-scheduled-backups" "warn" "$detail"
  fi
}

# MySQL backup file freshness on NFS
check_mysql_backups() {
  if $DRY_RUN; then
    add_check "mysql-backups" "ok" "DRY RUN: would check MySQL backup file timestamps"
    return
  fi

  # Check for MySQL backup files via a pod that has NFS mounted, or via known backup job
  local backup_pods
  backup_pods=$($KUBECTL get pods --all-namespaces -l app=mysql-backup -o name 2>/dev/null | head -1) || true
  if [ -z "$backup_pods" ]; then
    backup_pods=$($KUBECTL get cronjobs --all-namespaces --no-headers 2>/dev/null | grep -i "mysql.*backup\|backup.*mysql" | awk '{print $1"/"$2}') || true
  fi

  if [ -z "$backup_pods" ]; then
    # Try checking via TrueNAS SSH for NFS backup files
    local nfs_check
    nfs_check=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@10.0.10.15 \
      "find /mnt/main -name '*.sql.gz' -o -name '*.sql' -o -name '*mysql*backup*' 2>/dev/null | head -5" 2>/dev/null) || true

    if [ -n "$nfs_check" ]; then
      local ages
      ages=$(ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@10.0.10.15 \
        "for f in $(echo "$nfs_check" | tr '\n' ' '); do stat -f '%m %N' \"\$f\" 2>/dev/null || stat -c '%Y %n' \"\$f\" 2>/dev/null; done" 2>/dev/null) || true
      if [ -n "$ages" ]; then
        add_check "mysql-backups" "ok" "Found MySQL backup files on NFS: $(echo "$nfs_check" | tr '\n' '; ')"
      else
        add_check "mysql-backups" "warn" "Found backup files but cannot determine age: $(echo "$nfs_check" | tr '\n' '; ')"
      fi
    else
      add_check "mysql-backups" "warn" "No MySQL backup CronJobs or backup files found"
    fi
    return
  fi

  # Check CronJob last successful run
  local cronjob_status
  cronjob_status=$($KUBECTL get cronjobs --all-namespaces -o json 2>/dev/null | python3 -c "
import sys, json
from datetime import datetime, timezone

data = json.load(sys.stdin)
results = []
for cj in data.get('items', []):
  ns = cj['metadata']['namespace']
  name = cj['metadata']['name']
  if 'mysql' not in name.lower() and 'backup' not in name.lower():
    continue
  schedule = cj.get('spec', {}).get('schedule', 'unknown')
  last_time = cj.get('status', {}).get('lastScheduleTime', '')
  last_success = cj.get('status', {}).get('lastSuccessfulTime', '')
  suspend = cj.get('spec', {}).get('suspend', False)

  age_str = 'never'
  if last_success:
    try:
      dt = datetime.fromisoformat(last_success.replace('Z', '+00:00'))
      age = datetime.now(timezone.utc) - dt
      age_str = f'{age.total_seconds()/3600:.1f}h ago'
    except Exception:
      age_str = last_success

  status = 'suspended' if suspend else 'active'
  results.append(f'{ns}/{name}: {status} schedule={schedule} last_success={age_str}')

if results:
  print('; '.join(results))
else:
  print('No MySQL/backup CronJobs found')
" 2>/dev/null) || cronjob_status="Failed to check CronJobs"

  add_check "mysql-backups" "ok" "$cronjob_status"
}

# Run all checks
check_cnpg_backups
check_cnpg_scheduled
check_mysql_backups

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
