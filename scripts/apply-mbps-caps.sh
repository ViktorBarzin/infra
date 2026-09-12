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
#
# EXTRA_OPTS[vmid] adds per-VM options beyond the byte caps. It exists for
# IOPS caps, which the byte caps cannot express: sdc is oversubscribed on
# random IOPS, not on bandwidth. Measured 2026-09-08 — sdc serves ~560 r+w
# IOPS against the ~150-200 random IOPS a 7200rpm RAID1 pair can sustain,
# while bandwidth sits near 9-20 MB/s, so a 60 MB/s byte cap never binds
# (devvm uses 1.24% of its cap) and does nothing for the queue that etcd's
# fsync waits in.
TARGETS=(
  "102:scsi0:60:60"      # devvm
  "103:sata0:40:40"      # home-assistant
  "200:scsi0:100:60"     # k8s-master (alloy storm origin — firmest clip)
  "201:scsi1:150:120"    # k8s-node1 (GPU + many CSI disks; boots from scsi1)
  "202:scsi0:150:120"    # k8s-node2
  "203:scsi0:150:120"    # k8s-node3
  "204:scsi0:150:120"    # k8s-node4
  "205:scsi0:150:120"    # k8s-node5 (built after this list; uncapped until 2026-08-16)
  "220:scsi0:40:40"      # docker-registry
)

# Per-VM extra disk options, applied alongside the byte caps above.
#
# 102 devvm: read-IOPS cap. devvm averages 59.8 reads/s on sdc over 7 days and
# peaks at 1,123/s, the largest single read contributor in the windows where
# etcd's WAL fsync stalls (see docs/research/2026-09-06-etcd-fsync-root-cause.md).
# Reads are the ones that hurt: the PERC H730's battery-backed cache absorbs
# writes in 1.929 ms lifetime average, but it does not cache reads, which cost
# 4.483 ms each and queue in front of etcd's next write.
#
# RAISED 2026-09-12 from 120/400/10s to 400/800/30s, after the cap was measured
# as the dominant cost on the guest's interactive path.
#
# What 120 did to devvm. Read latency inside the guest was 190 ms while the host
# served the same LV in 21.65 ms; the ~168 ms difference is this token bucket,
# not the disk. The guest sat at or above the 120 ceiling in 10.8% of 5-minute
# windows over 7 days. Per-user cgroup pressure during a stall read
# io.pressure 73.93 with cpu.pressure 0.00 for the affected user, i.e. sessions
# were waiting on the bucket rather than on CPU or on the spindle.
#
# The 10s burst window was also too short for the case that hurts most. A tmux
# session whose pages have been reclaimed faults its working set back in over
# tens of seconds, not ten, so re-attaching to a session fell back to the
# sustained rate partway through and stalled.
#
# 400 sustained was already judged safe as a 10s burst by the 2026-09-08
# reasoning above; this makes it the sustained rate and moves the burst to
# 800/30s. Accepted risk, stated plainly: this can take sdc towards ~500
# reads/s against the 150-200 random IOPS the comment above attributes to a
# 7200rpm RAID1 pair. Host sdc measured 19.9% utilisation and 5.31 ms read
# await when this landed, so there is headroom, but not without limit. Watch
# etcd fsync latency and slow-op counts; revert this hunk if they regress.
#
# This is an interim unblock. The intended fix is an SSD read cache in front of
# the guest's root LV, which removes the reason for a read cap on this VM at
# all. Measured on a loop-device rig: 73.6% hit rate after 60 s of warming, and
# 394 MB written to cache a 400 MB working set at a 32 KiB block size.
#
# k8s-master (200) is deliberately left without an IOPS cap: it holds etcd, it
# reads 0.28/s, and it is the workload being protected.
declare -A EXTRA_OPTS=(
  [102]="iops_rd=400,iops_rd_max=800,iops_rd_max_length=30"
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

  cleaned=$(echo "$current" | sed -E '
    s/,mbps_rd=[0-9]+//g; s/,mbps_wr=[0-9]+//g;
    s/,iops_rd=[0-9]+//g; s/,iops_wr=[0-9]+//g;
    s/,iops_rd_max=[0-9]+//g; s/,iops_wr_max=[0-9]+//g;
    s/,iops_rd_max_length=[0-9]+//g; s/,iops_wr_max_length=[0-9]+//g')
  newvalue="${cleaned},mbps_rd=${rd},mbps_wr=${wr}"
  # Strip-then-reapply keeps the script idempotent when a cap value changes,
  # and lets removing a vmid from EXTRA_OPTS actually drop its IOPS cap.
  if [[ -n "${EXTRA_OPTS[$vmid]:-}" ]]; then
    newvalue="${newvalue},${EXTRA_OPTS[$vmid]}"
  fi

  # Skip the qm-set call entirely when state already matches — keeps
  # journal noise low under the hourly timer. Compare option SETS, not raw
  # strings: `qm config` prints keys in its own canonical order, so a raw
  # compare never matched and every hourly run re-issued `qm set`, which
  # live-rewrites the running VM's QEMU throttle state via QMP (implicated
  # in the 2026-06-11 devvm I/O stall — see
  # docs/post-mortems/2026-06-11-devvm-qemu-io-stall.md).
  if [[ "$(normalized "$current")" == "$(normalized "$newvalue")" ]]; then
    echo "vmid $vmid: $slot already at mbps_rd=${rd},mbps_wr=${wr}${EXTRA_OPTS[$vmid]:+,${EXTRA_OPTS[$vmid]}} — no-op"
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
