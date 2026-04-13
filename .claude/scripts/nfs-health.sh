#!/usr/bin/env bash
set -euo pipefail

AGENT="nfs-health"
KUBECTL="kubectl --kubeconfig /Users/viktorbarzin/code/infra/config"
NFS_HOST="192.168.1.127"
NODES=("k8s-master:10.0.20.100" "k8s-node1:10.0.20.101" "k8s-node2:10.0.20.102" "k8s-node3:10.0.20.103" "k8s-node4:10.0.20.104")
SSH_USER="wizard"
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

check_nfs_reachable() {
  if $DRY_RUN; then
    add_check "nfs-reachable" "ok" "dry-run: would ping $NFS_HOST"
    return
  fi
  if timeout 5 ping -c 1 "$NFS_HOST" &>/dev/null; then
    add_check "nfs-reachable" "ok" "Proxmox NFS at $NFS_HOST is reachable"
  else
    add_check "nfs-reachable" "fail" "Proxmox NFS at $NFS_HOST is unreachable"
  fi
}

check_nfs_exports() {
  if $DRY_RUN; then
    add_check "nfs-exports" "ok" "dry-run: would check NFS exports on Proxmox"
    return
  fi
  local result
  if result=$(timeout 10 ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "root@$NFS_HOST" \
    "exportfs -v 2>/dev/null || cat /etc/exports 2>/dev/null" 2>/dev/null); then
    local export_count
    export_count=$(echo "$result" | grep -c '/' || echo 0)
    if [ "$export_count" -gt 0 ]; then
      add_check "nfs-exports" "ok" "$export_count NFS exports active on Proxmox"
    else
      add_check "nfs-exports" "warn" "No NFS exports found on Proxmox"
    fi
  else
    add_check "nfs-exports" "fail" "Could not check NFS exports on Proxmox via SSH"
  fi
}

check_nfs_disk_usage() {
  if $DRY_RUN; then
    add_check "nfs-disk" "ok" "dry-run: would check NFS disk usage"
    return
  fi
  local result
  if result=$(timeout 10 ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "root@$NFS_HOST" \
    "df -h /srv/nfs /srv/nfs-ssd 2>/dev/null" 2>/dev/null); then
    while IFS= read -r line; do
      local mount pct
      mount=$(echo "$line" | awk '{print $6}')
      pct=$(echo "$line" | awk '{print $5}' | tr -d '%')
      [ -z "$pct" ] || ! [[ "$pct" =~ ^[0-9]+$ ]] && continue
      if [ "$pct" -ge 90 ]; then
        add_check "nfs-disk-$mount" "fail" "$mount is ${pct}% full"
      elif [ "$pct" -ge 80 ]; then
        add_check "nfs-disk-$mount" "warn" "$mount is ${pct}% full"
      else
        add_check "nfs-disk-$mount" "ok" "$mount is ${pct}% full"
      fi
    done <<< "$result"
  else
    add_check "nfs-disk" "warn" "Could not check NFS disk usage"
  fi
}

check_node_nfs_mounts() {
  local node_name="$1" node_ip="$2"

  if $DRY_RUN; then
    add_check "nfs-mounts-$node_name" "ok" "dry-run: would check NFS mounts on $node_name ($node_ip)"
    return
  fi

  local mount_output
  if ! mount_output=$(timeout 15 ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$SSH_USER@$node_ip" \
    "mount | grep nfs" 2>/dev/null); then
    add_check "nfs-mounts-$node_name" "warn" "No NFS mounts found or SSH failed on $node_name ($node_ip)"
    return
  fi

  if [ -z "$mount_output" ]; then
    add_check "nfs-mounts-$node_name" "warn" "No NFS mounts found on $node_name"
    return
  fi

  local mount_count
  mount_count=$(echo "$mount_output" | wc -l | tr -d ' ')

  # Check for stale mounts by trying to stat each mount point
  local stale_count=0
  local stale_mounts=""
  while IFS= read -r line; do
    local mount_point
    mount_point=$(echo "$line" | awk '{print $3}')
    if [ -n "$mount_point" ]; then
      if ! timeout 10 ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "$SSH_USER@$node_ip" \
        "timeout 5 stat '$mount_point' >/dev/null 2>&1" 2>/dev/null; then
        stale_count=$((stale_count + 1))
        stale_mounts="$stale_mounts $mount_point"
      fi
    fi
  done <<< "$mount_output"

  if [ "$stale_count" -gt 0 ]; then
    add_check "nfs-mounts-$node_name" "fail" "$stale_count/$mount_count NFS mounts stale on $node_name:$stale_mounts"
  else
    add_check "nfs-mounts-$node_name" "ok" "$mount_count NFS mounts healthy on $node_name"
  fi
}

check_nfs_pvcs() {
  if $DRY_RUN; then
    add_check "nfs-pvcs" "ok" "dry-run: would check NFS-backed PVCs"
    return
  fi

  local pending
  pending=$($KUBECTL get pvc --all-namespaces --field-selector='status.phase!=Bound' -o json 2>/dev/null | \
    python3 -c "import sys,json; items=json.load(sys.stdin).get('items',[]); nfs=[i for i in items if 'nfs' in json.dumps(i).lower()]; print(len(nfs))" 2>/dev/null || echo "error")

  if [ "$pending" = "error" ]; then
    add_check "nfs-pvcs" "warn" "Could not check NFS PVC status"
  elif [ "$pending" = "0" ]; then
    add_check "nfs-pvcs" "ok" "All NFS-backed PVCs are bound"
  else
    add_check "nfs-pvcs" "fail" "$pending NFS-backed PVCs are not bound"
  fi
}

# Run checks
check_nfs_reachable
check_nfs_exports
check_nfs_disk_usage

for node_entry in "${NODES[@]}"; do
  node_name="${node_entry%%:*}"
  node_ip="${node_entry##*:}"
  check_node_nfs_mounts "$node_name" "$node_ip"
done

check_nfs_pvcs

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
