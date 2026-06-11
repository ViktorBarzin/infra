#!/usr/bin/env bash
# Apply per-VM I/O caps via `qm set` on the PVE host.
#
# - Reads each target VM's current boot-disk options.
# - Appends/normalises `mbps_rd=<N>,mbps_wr=<N>`.
# - Re-applies via `qm set` (live, no reboot needed).
# - Idempotent: re-running with no drift is a no-op at the storage
#   level (proxmox config rewrite is cheap).
# - Continues on per-VM failures so one missing/stopped VM doesn't
#   skip the rest — designed to be safe under the systemd timer.
#
# Backed by `apply-mbps-caps.{service,timer}` (hourly + 5min-after-boot).
# Why these values: see beads code-9v2j + memory id=2726 (alloy IO storm)
# + memory id=1575 (VMs intentionally out of TF).

set -uo pipefail  # NOT -e — keep going if a single VM step fails.

# vmid:disk_slot:mbps_rd:mbps_wr  (Linux VMs only — skipping 101 pfsense BSD, 300 Windows)
TARGETS=(
  "102:scsi0:60:60"      # devvm
  "103:sata0:40:40"      # home-assistant
  "200:scsi0:100:60"     # k8s-master (alloy storm origin — firmest clip)
  "201:scsi1:150:120"    # k8s-node1 (GPU + many CSI disks; boots from scsi1)
  "202:scsi0:150:120"    # k8s-node2
  "203:scsi0:150:120"    # k8s-node3
  "204:scsi0:150:120"    # k8s-node4
  "220:scsi0:40:40"      # docker-registry
)

# Sort a disk spec's comma-separated options so two specs with the same
# option set but different key order compare equal.
normalized() {
  tr ',' '\n' <<<"$1" | LC_ALL=C sort | paste -sd, -
}

apply_one() {
  local spec="$1"
  local vmid slot rd wr
  IFS=: read -r vmid slot rd wr <<<"$spec"

  # Skip non-existent VMs cleanly (e.g. node decommissioned, never rebuilt).
  if ! qm status "$vmid" >/dev/null 2>&1; then
    echo "vmid $vmid: not present on this host — skipping"
    return 0
  fi

  local current cleaned newvalue
  current=$(qm config "$vmid" | awk -v s="$slot:" '$1==s {sub(/^[^ ]+ /, ""); print; exit}')
  if [[ -z "$current" ]]; then
    echo "vmid $vmid: no $slot line in config — skipping"
    return 0
  fi

  cleaned=$(echo "$current" | sed -E 's/,mbps_rd=[0-9]+//g; s/,mbps_wr=[0-9]+//g')
  newvalue="${cleaned},mbps_rd=${rd},mbps_wr=${wr}"

  # Skip the qm-set call entirely when state already matches — keeps
  # journal noise low under the hourly timer. Compare option SETS, not raw
  # strings: `qm config` prints keys in its own canonical order, so a raw
  # compare never matched and every hourly run re-issued `qm set`, which
  # live-rewrites the running VM's QEMU throttle state via QMP (implicated
  # in the 2026-06-11 devvm I/O stall — see
  # docs/post-mortems/2026-06-11-devvm-qemu-io-stall.md).
  if [[ "$(normalized "$current")" == "$(normalized "$newvalue")" ]]; then
    echo "vmid $vmid: $slot already at mbps_rd=${rd},mbps_wr=${wr} — no-op"
    return 0
  fi

  echo "vmid $vmid: updating $slot"
  echo "  before: $current"
  echo "  after:  $newvalue"
  if qm set "$vmid" "--$slot" "$newvalue"; then
    echo "  ok"
  else
    echo "  FAILED: qm set returned non-zero"
    return 1
  fi
}

rc=0
for spec in "${TARGETS[@]}"; do
  apply_one "$spec" || rc=1
done

exit "$rc"
