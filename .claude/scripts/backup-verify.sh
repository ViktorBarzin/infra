#!/usr/bin/env bash
# backup-verify.sh — Full 3-2-1 backup health inspection
# Checks: LVM snapshots, weekly backup, PVC file copies, pfsense, NFS mirror,
#          offsite sync, DB CronJobs, CNPG backups
# Usage: backup-verify.sh [--fix] [--dry-run]
set -euo pipefail

KUBECTL="kubectl --kubeconfig /Users/viktorbarzin/code/config"
PVE_SSH="ssh -o ConnectTimeout=5 -o BatchMode=yes root@192.168.1.127"
DRY_RUN=false
FIX=false
AGENT="backup-verify"

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --fix) FIX=true ;;
  esac
done

CHECKS="[]"
PVE_REACHABLE=true

add_check() {
  local name="$1" status="$2" message="$3"
  CHECKS=$(echo "$CHECKS" | python3 -c "
import sys, json
checks = json.load(sys.stdin)
checks.append({'name': '''$name''', 'status': '''$status''', 'message': '''$message'''})
json.dump(checks, sys.stdout)
")
}

# Test PVE host connectivity (all Layer 1+2 checks depend on this)
check_pve_connectivity() {
  if $DRY_RUN; then return; fi
  if ! $PVE_SSH "true" 2>/dev/null; then
    PVE_REACHABLE=false
    add_check "pve-connectivity" "fail" "PVE host (192.168.1.127) unreachable via SSH"
  fi
}

# ============================================================
# LAYER 1: LVM Thin Snapshots
# ============================================================

check_lvm_snapshot_freshness() {
  if $DRY_RUN; then add_check "lvm-snapshot-freshness" "ok" "DRY RUN"; return; fi
  if ! $PVE_REACHABLE; then add_check "lvm-snapshot-freshness" "fail" "PVE unreachable"; return; fi

  local ts
  ts=$($PVE_SSH "curl -s http://10.0.20.100:30091/metrics 2>/dev/null | grep '^lvm_snapshot_last_run_timestamp' | head -1 | awk '{print \$2}'" 2>/dev/null) || true

  if [ -z "$ts" ] || [ "$ts" = "" ]; then
    add_check "lvm-snapshot-freshness" "fail" "No Pushgateway metric found — snapshots may have never run"
    return
  fi

  local now age_h
  now=$(date +%s)
  age_h=$(python3 -c "print(f'{($now - $ts) / 3600:.1f}')" 2>/dev/null)

  if python3 -c "exit(0 if ($now - $ts) < 129600 else 1)" 2>/dev/null; then  # 36h
    add_check "lvm-snapshot-freshness" "ok" "Last snapshot ${age_h}h ago"
  elif python3 -c "exit(0 if ($now - $ts) < 172800 else 1)" 2>/dev/null; then  # 48h
    add_check "lvm-snapshot-freshness" "warn" "Snapshot getting stale: ${age_h}h ago (threshold: 36h)"
  else
    add_check "lvm-snapshot-freshness" "fail" "Snapshot stale: ${age_h}h ago (threshold: 48h)"
  fi
}

check_lvm_snapshot_status() {
  if $DRY_RUN; then add_check "lvm-snapshot-status" "ok" "DRY RUN"; return; fi
  if ! $PVE_REACHABLE; then add_check "lvm-snapshot-status" "fail" "PVE unreachable"; return; fi

  local status
  status=$($PVE_SSH "curl -s http://10.0.20.100:30091/metrics 2>/dev/null | grep '^lvm_snapshot_last_status' | head -1 | awk '{print \$2}'" 2>/dev/null) || true

  if [ "$status" = "0" ] || [ "$status" = "0.0" ]; then
    add_check "lvm-snapshot-status" "ok" "Last snapshot run succeeded"
  elif [ -z "$status" ]; then
    add_check "lvm-snapshot-status" "warn" "No status metric found"
  else
    add_check "lvm-snapshot-status" "fail" "Last snapshot run failed (status=$status)"
  fi
}

check_lvm_snapshot_count() {
  if $DRY_RUN; then add_check "lvm-snapshot-count" "ok" "DRY RUN"; return; fi
  if ! $PVE_REACHABLE; then add_check "lvm-snapshot-count" "fail" "PVE unreachable"; return; fi

  local count
  count=$($PVE_SSH "lvs pve 2>/dev/null | grep -c '_snap_' || echo 0" 2>/dev/null) || count=0

  if [ "$count" -ge 50 ]; then
    add_check "lvm-snapshot-count" "ok" "${count} snapshots exist"
  elif [ "$count" -gt 0 ]; then
    add_check "lvm-snapshot-count" "warn" "Only ${count} snapshots (expected ≥50)"
  else
    add_check "lvm-snapshot-count" "fail" "No snapshots exist"
  fi
}

check_lvm_thinpool_free() {
  if $DRY_RUN; then add_check "lvm-thinpool-free" "ok" "DRY RUN"; return; fi
  if ! $PVE_REACHABLE; then add_check "lvm-thinpool-free" "fail" "PVE unreachable"; return; fi

  local data_pct free_pct
  data_pct=$($PVE_SSH "lvs --noheadings --nosuffix -o data_percent pve/data 2>/dev/null | tr -d ' '" 2>/dev/null) || true

  if [ -z "$data_pct" ]; then
    add_check "lvm-thinpool-free" "warn" "Cannot read thin pool usage"
    return
  fi

  free_pct=$(python3 -c "print(f'{100 - $data_pct:.1f}')" 2>/dev/null)

  if python3 -c "exit(0 if (100 - $data_pct) > 15 else 1)" 2>/dev/null; then
    add_check "lvm-thinpool-free" "ok" "Thin pool ${free_pct}% free"
  elif python3 -c "exit(0 if (100 - $data_pct) > 10 else 1)" 2>/dev/null; then
    add_check "lvm-thinpool-free" "warn" "Thin pool low: ${free_pct}% free (threshold: 15%)"
  else
    add_check "lvm-thinpool-free" "fail" "Thin pool critical: ${free_pct}% free (threshold: 10%)"
  fi
}

check_lvm_snapshot_timer() {
  if $DRY_RUN; then add_check "lvm-snapshot-timer" "ok" "DRY RUN"; return; fi
  if ! $PVE_REACHABLE; then add_check "lvm-snapshot-timer" "fail" "PVE unreachable"; return; fi

  local active enabled
  active=$($PVE_SSH "systemctl is-active lvm-pvc-snapshot.timer 2>/dev/null" 2>/dev/null) || active="unknown"
  enabled=$($PVE_SSH "systemctl is-enabled lvm-pvc-snapshot.timer 2>/dev/null" 2>/dev/null) || enabled="unknown"

  if [ "$active" = "active" ] && [ "$enabled" = "enabled" ]; then
    add_check "lvm-snapshot-timer" "ok" "Timer active and enabled"
  else
    add_check "lvm-snapshot-timer" "fail" "Timer: active=$active enabled=$enabled"
    if $FIX; then
      $PVE_SSH "systemctl enable --now lvm-pvc-snapshot.timer" 2>/dev/null && \
        add_check "lvm-snapshot-timer-fix" "ok" "AUTO-FIX: Timer re-enabled" || \
        add_check "lvm-snapshot-timer-fix" "fail" "AUTO-FIX: Failed to re-enable timer"
    fi
  fi
}

# ============================================================
# LAYER 2: Weekly Backup (sda)
# ============================================================

check_daily_backup_freshness() {
  if $DRY_RUN; then add_check "daily-backup-freshness" "ok" "DRY RUN"; return; fi
  if ! $PVE_REACHABLE; then add_check "daily-backup-freshness" "fail" "PVE unreachable"; return; fi

  local ts
  ts=$($PVE_SSH "curl -s http://10.0.20.100:30091/metrics 2>/dev/null | grep '^daily_backup_last_run_timestamp' | head -1 | awk '{print \$2}'" 2>/dev/null) || true

  if [ -z "$ts" ]; then
    add_check "daily-backup-freshness" "fail" "No weekly backup metric — may have never run"
    return
  fi

  local now age_h
  now=$(date +%s)
  age_h=$(python3 -c "print(f'{($now - $ts) / 3600:.1f}')" 2>/dev/null)

  if python3 -c "exit(0 if ($now - $ts) < 777600 else 1)" 2>/dev/null; then  # 9d
    add_check "daily-backup-freshness" "ok" "Last run ${age_h}h ago"
  else
    add_check "daily-backup-freshness" "fail" "Daily backup stale: ${age_h}h ago (threshold: 9d)"
  fi
}

check_daily_backup_status() {
  if $DRY_RUN; then add_check "daily-backup-status" "ok" "DRY RUN"; return; fi
  if ! $PVE_REACHABLE; then add_check "daily-backup-status" "fail" "PVE unreachable"; return; fi

  local status
  status=$($PVE_SSH "curl -s http://10.0.20.100:30091/metrics 2>/dev/null | grep '^daily_backup_last_status' | head -1 | awk '{print \$2}'" 2>/dev/null) || true

  if [ "$status" = "0" ] || [ "$status" = "0.0" ]; then
    add_check "daily-backup-status" "ok" "Last weekly backup succeeded"
  elif [ -z "$status" ]; then
    add_check "daily-backup-status" "warn" "No status metric found"
  else
    add_check "daily-backup-status" "fail" "Last weekly backup failed (status=$status)"
  fi
}

check_daily_backup_timer() {
  if $DRY_RUN; then add_check "daily-backup-timer" "ok" "DRY RUN"; return; fi
  if ! $PVE_REACHABLE; then add_check "daily-backup-timer" "fail" "PVE unreachable"; return; fi

  local active enabled
  active=$($PVE_SSH "systemctl is-active daily-backup.timer 2>/dev/null" 2>/dev/null) || active="unknown"
  enabled=$($PVE_SSH "systemctl is-enabled daily-backup.timer 2>/dev/null" 2>/dev/null) || enabled="unknown"

  if [ "$active" = "active" ] && [ "$enabled" = "enabled" ]; then
    add_check "daily-backup-timer" "ok" "Timer active and enabled"
  else
    add_check "daily-backup-timer" "fail" "Timer: active=$active enabled=$enabled"
    if $FIX; then
      $PVE_SSH "systemctl enable --now daily-backup.timer" 2>/dev/null && \
        add_check "daily-backup-timer-fix" "ok" "AUTO-FIX: Timer re-enabled" || \
        add_check "daily-backup-timer-fix" "fail" "AUTO-FIX: Failed to re-enable timer"
    fi
  fi
}

check_sda_mount() {
  if $DRY_RUN; then add_check "sda-mount" "ok" "DRY RUN"; return; fi
  if ! $PVE_REACHABLE; then add_check "sda-mount" "fail" "PVE unreachable"; return; fi

  if $PVE_SSH "mountpoint -q /mnt/backup" 2>/dev/null; then
    add_check "sda-mount" "ok" "/mnt/backup is mounted"
  else
    add_check "sda-mount" "fail" "/mnt/backup is NOT mounted"
    if $FIX; then
      $PVE_SSH "mount /mnt/backup" 2>/dev/null && \
        add_check "sda-mount-fix" "ok" "AUTO-FIX: Mounted /mnt/backup" || \
        add_check "sda-mount-fix" "fail" "AUTO-FIX: Failed to mount /mnt/backup"
    fi
  fi
}

check_sda_disk_usage() {
  if $DRY_RUN; then add_check "sda-disk-usage" "ok" "DRY RUN"; return; fi
  if ! $PVE_REACHABLE; then add_check "sda-disk-usage" "fail" "PVE unreachable"; return; fi

  local usage_pct
  usage_pct=$($PVE_SSH "df --output=pcent /mnt/backup 2>/dev/null | tail -1 | tr -d ' %'" 2>/dev/null) || true

  if [ -z "$usage_pct" ]; then
    add_check "sda-disk-usage" "warn" "Cannot read /mnt/backup usage"
    return
  fi

  if [ "$usage_pct" -lt 85 ]; then
    add_check "sda-disk-usage" "ok" "Backup disk ${usage_pct}% used"
  elif [ "$usage_pct" -lt 95 ]; then
    add_check "sda-disk-usage" "warn" "Backup disk ${usage_pct}% used (threshold: 85%)"
  else
    add_check "sda-disk-usage" "fail" "Backup disk ${usage_pct}% used (threshold: 95%)"
  fi
}

check_pvc_data_freshness() {
  if $DRY_RUN; then add_check "pvc-data-freshness" "ok" "DRY RUN"; return; fi
  if ! $PVE_REACHABLE; then add_check "pvc-data-freshness" "fail" "PVE unreachable"; return; fi

  local latest_week count
  latest_week=$($PVE_SSH "ls -1d /mnt/backup/pvc-data/????-?? 2>/dev/null | tail -1" 2>/dev/null) || true
  count=$($PVE_SSH "ls -1d /mnt/backup/pvc-data/????-??/*/* 2>/dev/null | wc -l" 2>/dev/null) || count=0

  if [ -z "$latest_week" ]; then
    add_check "pvc-data-freshness" "fail" "No PVC file copies found on sda"
  else
    local week_name age_days
    week_name=$(basename "$latest_week")
    # Check age of latest week dir
    age_days=$($PVE_SSH "echo \$(( (\$(date +%s) - \$(stat -c %Y '$latest_week')) / 86400 ))" 2>/dev/null) || age_days=999
    if [ "$age_days" -lt 9 ]; then
      add_check "pvc-data-freshness" "ok" "PVC copies: week ${week_name}, ${count} PVCs, ${age_days}d old"
    else
      add_check "pvc-data-freshness" "fail" "PVC copies stale: week ${week_name}, ${age_days}d old (threshold: 9d)"
    fi
  fi
}

check_nfs_mirror_freshness() {
  if $DRY_RUN; then add_check "nfs-mirror-freshness" "ok" "DRY RUN"; return; fi
  if ! $PVE_REACHABLE; then add_check "nfs-mirror-freshness" "fail" "PVE unreachable"; return; fi

  local dir_count age_days
  dir_count=$($PVE_SSH "ls -1d /mnt/backup/nfs-mirror/*-backup 2>/dev/null | wc -l" 2>/dev/null) || dir_count=0
  age_days=$($PVE_SSH "echo \$(( (\$(date +%s) - \$(stat -c %Y /mnt/backup/nfs-mirror 2>/dev/null || echo 0)) / 86400 ))" 2>/dev/null) || age_days=999

  if [ "$dir_count" -gt 0 ] && [ "$age_days" -lt 9 ]; then
    add_check "nfs-mirror-freshness" "ok" "NFS mirror: ${dir_count} dirs, ${age_days}d old"
  elif [ "$dir_count" -eq 0 ]; then
    add_check "nfs-mirror-freshness" "fail" "No NFS mirror dirs found on sda"
  else
    add_check "nfs-mirror-freshness" "fail" "NFS mirror stale: ${age_days}d old (threshold: 9d)"
  fi
}

check_pfsense_backup_freshness() {
  if $DRY_RUN; then add_check "pfsense-backup-freshness" "ok" "DRY RUN"; return; fi
  if ! $PVE_REACHABLE; then add_check "pfsense-backup-freshness" "fail" "PVE unreachable"; return; fi

  local latest age_days
  latest=$($PVE_SSH "ls -t /mnt/backup/pfsense/config-*.xml 2>/dev/null | head -1" 2>/dev/null) || true

  if [ -z "$latest" ]; then
    add_check "pfsense-backup-freshness" "fail" "No pfsense config.xml backups found"
    return
  fi

  age_days=$($PVE_SSH "echo \$(( (\$(date +%s) - \$(stat -c %Y '$latest')) / 86400 ))" 2>/dev/null) || age_days=999
  local fname
  fname=$(basename "$latest")

  if [ "$age_days" -lt 9 ]; then
    add_check "pfsense-backup-freshness" "ok" "pfsense backup: ${fname}, ${age_days}d old"
  else
    add_check "pfsense-backup-freshness" "fail" "pfsense backup stale: ${fname}, ${age_days}d old (threshold: 9d)"
  fi
}

# ============================================================
# LAYER 3: Offsite Sync
# ============================================================

check_offsite_sync_freshness() {
  if $DRY_RUN; then add_check "offsite-sync-freshness" "ok" "DRY RUN"; return; fi
  if ! $PVE_REACHABLE; then add_check "offsite-sync-freshness" "fail" "PVE unreachable"; return; fi

  local ts
  ts=$($PVE_SSH "curl -s http://10.0.20.100:30091/metrics 2>/dev/null | grep 'backup_last_success_timestamp.*offsite-backup-sync' | awk '{print \$NF}'" 2>/dev/null) || true

  if [ -z "$ts" ]; then
    add_check "offsite-sync-freshness" "fail" "No offsite sync metric — may have never run"
    return
  fi

  local now age_h
  now=$(date +%s)
  age_h=$(python3 -c "print(f'{($now - $ts) / 3600:.1f}')" 2>/dev/null)

  if python3 -c "exit(0 if ($now - $ts) < 777600 else 1)" 2>/dev/null; then  # 9d
    add_check "offsite-sync-freshness" "ok" "Last offsite sync ${age_h}h ago"
  else
    add_check "offsite-sync-freshness" "fail" "Offsite sync stale: ${age_h}h ago (threshold: 9d)"
  fi
}

check_offsite_sync_status() {
  if $DRY_RUN; then add_check "offsite-sync-status" "ok" "DRY RUN"; return; fi
  if ! $PVE_REACHABLE; then add_check "offsite-sync-status" "fail" "PVE unreachable"; return; fi

  local status
  status=$($PVE_SSH "curl -s http://10.0.20.100:30091/metrics 2>/dev/null | grep '^offsite_sync_last_status' | head -1 | awk '{print \$2}'" 2>/dev/null) || true

  if [ "$status" = "0" ] || [ "$status" = "0.0" ]; then
    add_check "offsite-sync-status" "ok" "Last offsite sync succeeded"
  elif [ -z "$status" ]; then
    add_check "offsite-sync-status" "warn" "No offsite sync status metric"
  else
    add_check "offsite-sync-status" "fail" "Last offsite sync failed (status=$status)"
  fi
}

check_offsite_sync_timer() {
  if $DRY_RUN; then add_check "offsite-sync-timer" "ok" "DRY RUN"; return; fi
  if ! $PVE_REACHABLE; then add_check "offsite-sync-timer" "fail" "PVE unreachable"; return; fi

  local active enabled
  active=$($PVE_SSH "systemctl is-active offsite-sync-backup.timer 2>/dev/null" 2>/dev/null) || active="unknown"
  enabled=$($PVE_SSH "systemctl is-enabled offsite-sync-backup.timer 2>/dev/null" 2>/dev/null) || enabled="unknown"

  if [ "$active" = "active" ] && [ "$enabled" = "enabled" ]; then
    add_check "offsite-sync-timer" "ok" "Timer active and enabled"
  else
    add_check "offsite-sync-timer" "fail" "Timer: active=$active enabled=$enabled"
    if $FIX; then
      $PVE_SSH "systemctl enable --now offsite-sync-backup.timer" 2>/dev/null && \
        add_check "offsite-sync-timer-fix" "ok" "AUTO-FIX: Timer re-enabled" || \
        add_check "offsite-sync-timer-fix" "fail" "AUTO-FIX: Failed to re-enable timer"
    fi
  fi
}

# ============================================================
# DB BACKUP CRONJOBS
# ============================================================

check_backup_cronjobs() {
  if $DRY_RUN; then add_check "backup-cronjobs" "ok" "DRY RUN"; return; fi

  local report
  report=$($KUBECTL get cronjobs --all-namespaces -o json 2>/dev/null | python3 -c "
import sys, json
from datetime import datetime, timezone

data = json.load(sys.stdin)
# CronJobs with backup-related names
backup_cjs = []
for cj in data.get('items', []):
    name = cj['metadata']['name']
    ns = cj['metadata']['namespace']
    if any(k in name.lower() for k in ['backup', 'etcd', 'raft']):
        backup_cjs.append(cj)

if not backup_cjs:
    print('WARN|No backup CronJobs found')
    sys.exit(0)

# Thresholds in hours
thresholds = {
    'mysql': 36, 'postgresql': 36, 'immich': 36,
    'vault': 216, 'etcd': 216, 'redis': 216,
    'vaultwarden': 216, 'plotting': 216, 'headscale': 216,
    'prometheus': 840,  # 35 days
}

results = []
all_ok = True
now = datetime.now(timezone.utc)
for cj in backup_cjs:
    ns = cj['metadata']['namespace']
    name = cj['metadata']['name']
    last_success = cj.get('status', {}).get('lastSuccessfulTime', '')
    suspend = cj.get('spec', {}).get('suspend', False)

    # Find matching threshold
    threshold_h = 216  # default 9 days
    for key, th in thresholds.items():
        if key in name.lower():
            threshold_h = th
            break

    if suspend:
        all_ok = False
        results.append(f'FAIL {ns}/{name}: SUSPENDED')
        continue

    if not last_success:
        results.append(f'WARN {ns}/{name}: never succeeded')
        all_ok = False
        continue

    try:
        dt = datetime.fromisoformat(last_success.replace('Z', '+00:00'))
        age_h = (now - dt).total_seconds() / 3600
        if age_h > threshold_h:
            all_ok = False
            results.append(f'FAIL {ns}/{name}: {age_h:.0f}h ago (threshold: {threshold_h}h)')
        else:
            results.append(f'OK {ns}/{name}: {age_h:.0f}h ago')
    except Exception:
        results.append(f'WARN {ns}/{name}: cannot parse time {last_success}')
        all_ok = False

status = 'OK' if all_ok else 'WARN'
print(f'{status}|' + '; '.join(results))
" 2>/dev/null) || report="WARN|Failed to check backup CronJobs"

  local status_prefix="${report%%|*}"
  local detail="${report#*|}"

  if [ "$status_prefix" = "OK" ]; then
    add_check "backup-cronjobs" "ok" "$detail"
  else
    add_check "backup-cronjobs" "warn" "$detail"
  fi
}

# ============================================================
# CNPG BACKUPS (existing checks, kept as-is)
# ============================================================

check_cnpg_backups() {
  if $DRY_RUN; then add_check "cnpg-backups" "ok" "DRY RUN"; return; fi

  local backups
  backups=$($KUBECTL get backup.postgresql.cnpg.io --all-namespaces -o json 2>/dev/null) || {
    add_check "cnpg-backups" "warn" "No CNPG Backup CRDs found"
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

clusters = {}
for b in items:
  ns = b['metadata']['namespace']
  cluster = b.get('spec', {}).get('cluster', {}).get('name', 'unknown')
  key = f'{ns}/{cluster}'
  stopped = b.get('status', {}).get('stoppedAt', '')
  phase = b.get('status', {}).get('phase', 'unknown')
  if key not in clusters or stopped > clusters[key].get('stopped', ''):
    clusters[key] = {'phase': phase, 'stopped': stopped}

results = []
all_ok = True
now = datetime.now(timezone.utc)
for key, info in sorted(clusters.items()):
  if info['stopped']:
    try:
      dt = datetime.fromisoformat(info['stopped'].replace('Z', '+00:00'))
      age_h = (now - dt).total_seconds() / 3600
      if age_h > 48: all_ok = False
      results.append(f'{key}: {info[\"phase\"]} ({age_h:.1f}h ago)')
    except: results.append(f'{key}: {info[\"phase\"]}'); all_ok = False
  else:
    results.append(f'{key}: {info[\"phase\"]} (no completion)'); all_ok = False

print(f'{\"OK\" if all_ok else \"WARN\"}|' + '; '.join(results))
" 2>/dev/null) || report="WARN|Failed to parse CNPG backups"

  local status_prefix="${report%%|*}"
  local detail="${report#*|}"
  if [ "$status_prefix" = "OK" ]; then
    add_check "cnpg-backups" "ok" "$detail"
  else
    add_check "cnpg-backups" "warn" "$detail"
  fi
}

# ============================================================
# RUN ALL CHECKS
# ============================================================

check_pve_connectivity

# Layer 1: LVM Thin Snapshots
check_lvm_snapshot_freshness
check_lvm_snapshot_status
check_lvm_snapshot_count
check_lvm_thinpool_free
check_lvm_snapshot_timer

# Layer 2: Weekly Backup (sda)
check_daily_backup_freshness
check_daily_backup_status
check_daily_backup_timer
check_sda_mount
check_sda_disk_usage
check_pvc_data_freshness
check_nfs_mirror_freshness
check_pfsense_backup_freshness

# Layer 3: Offsite Sync
check_offsite_sync_freshness
check_offsite_sync_status
check_offsite_sync_timer

# DB CronJobs + CNPG
check_backup_cronjobs
check_cnpg_backups

# ============================================================
# OUTPUT
# ============================================================

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
