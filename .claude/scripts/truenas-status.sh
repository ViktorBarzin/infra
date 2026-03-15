#!/usr/bin/env bash
set -euo pipefail

AGENT="truenas-status"
TRUENAS_HOST="root@10.0.10.15"
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

ssh_cmd() {
  timeout 15 ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$TRUENAS_HOST" "$@" 2>/dev/null
}

check_zfs_pools() {
  if $DRY_RUN; then
    add_check "zfs-pools" "ok" "dry-run: would check ZFS pool status"
    return
  fi

  local pool_status
  if ! pool_status=$(ssh_cmd "zpool status -x" 2>/dev/null); then
    add_check "zfs-pools" "fail" "Could not retrieve ZFS pool status via SSH"
    return
  fi

  if echo "$pool_status" | grep -q "all pools are healthy"; then
    add_check "zfs-pools" "ok" "All ZFS pools are healthy"
  else
    local degraded_pools
    degraded_pools=$(echo "$pool_status" | grep "pool:" | awk '{print $2}' | tr '\n' ', ' | sed 's/,$//')
    if [ -n "$degraded_pools" ]; then
      add_check "zfs-pools" "fail" "Degraded ZFS pools: $degraded_pools"
    else
      add_check "zfs-pools" "warn" "ZFS pool status unclear: $(echo "$pool_status" | head -1 | tr '"' "'")"
    fi
  fi

  # Check pool capacity
  local pool_list
  if pool_list=$(ssh_cmd "zpool list -H -o name,cap" 2>/dev/null); then
    while IFS=$'\t' read -r pool_name cap_pct; do
      local cap_num
      cap_num=$(echo "$cap_pct" | tr -d '%')
      if [ -n "$cap_num" ] && [ "$cap_num" -ge 90 ]; then
        add_check "zfs-capacity-$pool_name" "fail" "Pool $pool_name is ${cap_pct} full"
      elif [ -n "$cap_num" ] && [ "$cap_num" -ge 80 ]; then
        add_check "zfs-capacity-$pool_name" "warn" "Pool $pool_name is ${cap_pct} full"
      else
        add_check "zfs-capacity-$pool_name" "ok" "Pool $pool_name is ${cap_pct} full"
      fi
    done <<< "$pool_list"
  fi
}

check_smart_health() {
  if $DRY_RUN; then
    add_check "smart-health" "ok" "dry-run: would check SMART disk health"
    return
  fi

  local disk_list
  if ! disk_list=$(ssh_cmd "smartctl --scan" 2>/dev/null); then
    add_check "smart-health" "warn" "Could not scan disks for SMART status"
    return
  fi

  local fail_count=0
  local total_count=0
  local failed_disks=""

  while IFS= read -r line; do
    local dev
    dev=$(echo "$line" | awk '{print $1}')
    [ -z "$dev" ] && continue
    total_count=$((total_count + 1))

    local health
    if health=$(ssh_cmd "smartctl -H '$dev'" 2>/dev/null); then
      if ! echo "$health" | grep -qiE "PASSED|OK"; then
        fail_count=$((fail_count + 1))
        failed_disks="$failed_disks $dev"
      fi
    fi
  done <<< "$disk_list"

  if [ "$fail_count" -gt 0 ]; then
    add_check "smart-health" "fail" "$fail_count/$total_count disks failing SMART:$failed_disks"
  elif [ "$total_count" -gt 0 ]; then
    add_check "smart-health" "ok" "All $total_count disks pass SMART health checks"
  else
    add_check "smart-health" "warn" "No disks found for SMART check"
  fi
}

check_replication() {
  if $DRY_RUN; then
    add_check "replication" "ok" "dry-run: would check replication task status"
    return
  fi

  # Check for any running/failed replication tasks via midclt if available
  local repl_status
  if repl_status=$(ssh_cmd "midclt call replication.query 2>/dev/null" 2>/dev/null); then
    local failed
    failed=$(echo "$repl_status" | python3 -c "
import sys, json
try:
    tasks = json.load(sys.stdin)
    failed = [t.get('name','unknown') for t in tasks if t.get('state',{}).get('state','') == 'ERROR']
    print(len(failed))
except: print('error')
" 2>/dev/null || echo "error")

    if [ "$failed" = "error" ]; then
      add_check "replication" "warn" "Could not parse replication task status"
    elif [ "$failed" = "0" ]; then
      add_check "replication" "ok" "All replication tasks healthy"
    else
      add_check "replication" "fail" "$failed replication tasks in ERROR state"
    fi
  else
    # Fallback: check if zfs send/recv processes are stuck
    local send_procs
    send_procs=$(ssh_cmd "pgrep -c 'zfs send' 2>/dev/null || echo 0")
    add_check "replication" "warn" "midclt unavailable; $send_procs active zfs send processes"
  fi
}

check_iscsi() {
  if $DRY_RUN; then
    add_check "iscsi-targets" "ok" "dry-run: would check iSCSI target status"
    return
  fi

  local target_status
  if target_status=$(ssh_cmd "ctladm islist 2>/dev/null || targetcli ls 2>/dev/null" 2>/dev/null); then
    local target_count
    target_count=$(echo "$target_status" | wc -l | tr -d ' ')
    if [ "$target_count" -gt 0 ]; then
      add_check "iscsi-targets" "ok" "iSCSI service active with $target_count entries"
    else
      add_check "iscsi-targets" "warn" "iSCSI service active but no targets listed"
    fi
  else
    # Try checking if the service is at least running
    if ssh_cmd "midclt call iscsi.global.config" &>/dev/null; then
      add_check "iscsi-targets" "ok" "iSCSI service is configured and running"
    else
      add_check "iscsi-targets" "warn" "Could not query iSCSI target status"
    fi
  fi
}

# Run checks
check_zfs_pools
check_smart_health
check_replication
check_iscsi

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
