#!/usr/bin/env bash
# Delegate the cgroup v2 `io` controller into qemu.slice on the PVE host.
#
# WHY. Without this, /sys/fs/cgroup/qemu.slice/200.scope has no io.* files and
# there is no way to ask "how much disk IO did THIS VM do". Per-dm-device host
# stats can be mapped back to an LV by hand, but that misses anything a VM does
# outside its own disk, and it cannot be joined to a cgroup. With `io`
# delegated, each <vmid>.scope grows an io.stat that reports rbytes/wbytes and
# rios/wios per backing device, which is the attribution the 2026-09-06 etcd
# fsync investigation had to reconstruct indirectly.
#
# Verified on the live host 2026-09-08: after delegation, 200.scope/io.stat
# reports 8:32 (sdc), 252:5, 252:6 and 252:220, so a VM's IO is accounted at
# the physical device as well as at each dm layer it passes through.
#
# WHAT THE DELEGATION DOES NOT DO. It sets no IO limits. Delegation only turns
# on accounting, and every io.* knob keeps its default.
#
# io.latency is NOT available on this kernel: 6.14.11-4-pve was built without
# CONFIG_BLK_CGROUP_IOLATENCY, and 7.0.14-25-pve (checked 2026-11-04) still is, so the latency-target approach the research doc
# proposed cannot be used here. CONFIG_BLK_CGROUP_IOCOST=y and bfq are both
# present, so io.weight over blk-iocost is the work-conserving option if a
# guarantee is ever wanted. That needs a cost model for a rotational device and
# can throttle every guest if it is wrong, so it is deliberately not enabled
# here.
#
# Idempotent: re-running when `io` is already delegated writes nothing. Safe
# under the systemd timer. Reverse by hand with:
#   echo '-io' > /sys/fs/cgroup/qemu.slice/cgroup.subtree_control
#
# SWAP POLICY (added 2026-11-05). The host swap LV (pve/swap, 8 GiB) lives on
# sdc, the spindle etcd writes its WAL to. On 2026-11-04 it was full (2 MB
# free) at the default swappiness of 60, k8s-master (VM 200, etcd) had 1.2 GB
# swapped out, and both daytime etcd stalls on 2026-11-05 (08:05 and 16:25 UTC,
# ~420 ms) carried 50-70 swap-in reads/s. On 2026-11-02 a page-cache surge from
# an NFS-heavy tv conversion swapped ~5 GiB onto sdc at 807 writes/s and etcd
# reached 5.5 s. Two settings:
#   - vm.swappiness=10, so the kernel drops page cache before swapping VM
#     memory. Declared in playbooks/pve-host.yml (/etc/sysctl.d), not here.
#   - memory.swap.max=0 on 200.scope, so etcd's VM is never swapped. This
#     script owns it: the scope is recreated when the VM restarts, hence
#     re-asserting it on every run. Pages already in swap stay there until
#     touched; nothing is forced back in.
# Deliberately NOT done: swapoff. It re-reads everything in swap from sdc at
# once (7.8 GB on 2026-11-04) and swap refilled within ~3 days anyway.
# Reverse by hand: echo max > /sys/fs/cgroup/qemu.slice/200.scope/memory.swap.max
# (and drop 200 from NO_SWAP_VMIDS, or the next run sets it again).
#
# Backed by pve-cgroup-io.{service,timer}. Same install pattern as
# apply-mbps-caps.sh: copy to /usr/local/bin, enable the timer.

set -uo pipefail

SLICE=/sys/fs/cgroup/qemu.slice
NO_SWAP_VMIDS=(200)   # k8s-master: etcd

# Runs on every exit path (EXIT trap), so the early "already delegated" exits
# below still apply it.
apply_swap_policy() {
  local vmid f
  for vmid in "${NO_SWAP_VMIDS[@]}"; do
    f="$SLICE/$vmid.scope/memory.swap.max"
    if [[ ! -f "$f" ]]; then
      echo "$vmid.scope: not running — skipping memory.swap.max"
    elif [[ "$(cat "$f")" == "0" ]]; then
      echo "$vmid.scope: memory.swap.max already 0 — no-op"
    elif echo 0 > "$f"; then
      echo "$vmid.scope: memory.swap.max -> 0"
    else
      echo "FAILED to set $f"
    fi
  done
}
trap apply_swap_policy EXIT

if [[ ! -d "$SLICE" ]]; then
  echo "qemu.slice not present — no VMs running under it, nothing to do"
  exit 0
fi

if [[ ! -f "$SLICE/cgroup.subtree_control" ]]; then
  echo "no cgroup.subtree_control in $SLICE — not cgroup v2, nothing to do"
  exit 0
fi

# The parent must offer `io` before it can be delegated downward.
if ! grep -qw io "$SLICE/cgroup.controllers"; then
  echo "io controller not available in $SLICE/cgroup.controllers — skipping"
  exit 0
fi

if grep -qw io "$SLICE/cgroup.subtree_control"; then
  echo "io already delegated into qemu.slice — no-op"
  exit 0
fi

if echo '+io' > "$SLICE/cgroup.subtree_control"; then
  echo "delegated io into qemu.slice"
else
  echo "FAILED to write +io to $SLICE/cgroup.subtree_control"
  exit 1
fi

# Report what became visible, so the journal shows the change took effect.
for scope in "$SLICE"/*.scope; do
  [[ -f "$scope/io.stat" ]] || continue
  echo "  $(basename "$scope"): io.stat present"
done
