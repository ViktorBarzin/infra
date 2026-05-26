#!/usr/bin/env bash
# Apply per-VM I/O caps via qm set on the PVE host.
# - Reads each VM's current boot-disk options
# - Appends mbps_rd=<N>,mbps_wr=<N>
# - Re-applies via qm set (live, no reboot needed)
# - Verifies with qm config | grep mbps
set -euo pipefail

# vmid:disk_slot:mbps_rd:mbps_wr  (Linux VMs only — skipping 101 pfsense BSD, 300 Windows)
TARGETS=(
  "102:scsi0:60:60"      # devvm
  "103:sata0:40:40"      # home-assistant
  "200:scsi0:100:60"     # k8s-master (alloy storm origin — firmest clip)
  "201:scsi1:150:120"    # k8s-node1 (GPU + many CSI disks; boots from scsi1)
  "202:scsi0:150:120"    # k8s-node2
  "203:scsi0:150:120"    # k8s-node3
  "204:scsi0:150:120"    # k8s-node4 (currently doing write recovery)
  "220:scsi0:40:40"      # docker-registry
)

for spec in "${TARGETS[@]}"; do
  IFS=: read -r vmid slot rd wr <<<"$spec"
  printf '\n=== VMID %s slot=%s rd=%s MB/s wr=%s MB/s ===\n' "$vmid" "$slot" "$rd" "$wr"

  current=$(qm config "$vmid" | awk -v s="$slot:" '$1==s {sub(/^[^ ]+ /, ""); print; exit}')
  if [[ -z "$current" ]]; then
    echo "  ERROR: could not read $slot for vmid $vmid — skipping"
    continue
  fi

  # Strip any existing mbps_rd / mbps_wr from the current string (idempotent)
  cleaned=$(echo "$current" | sed -E 's/,mbps_rd=[0-9]+//g; s/,mbps_wr=[0-9]+//g')
  newvalue="${cleaned},mbps_rd=${rd},mbps_wr=${wr}"

  echo "  before: $current"
  echo "  after:  $newvalue"

  qm set "$vmid" "--$slot" "$newvalue"
  echo "  verify: $(qm config "$vmid" | awk -v s="$slot:" '$1==s {print; exit}')"
done

echo
echo "=== Final verification — mbps on all targets ==="
for spec in "${TARGETS[@]}"; do
  IFS=: read -r vmid slot _ _ <<<"$spec"
  echo "vmid $vmid: $(qm config "$vmid" | awk -v s="$slot:" '$1==s {print; exit}')"
done
