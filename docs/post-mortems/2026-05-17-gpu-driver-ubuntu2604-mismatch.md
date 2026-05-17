# Post-Mortem: GPU Driver Crashloop after Ubuntu 26.04 Upgrade on k8s-node1

**Date:** 2026-05-17
**Author:** Viktor Barzin / Claude (incident response)
**Severity:** SEV-3 (GPU workloads unavailable: frigate, immich-ml, llama-swap, ytdlp/yt-highlights all Pending; no impact to non-GPU services)
**Beads:** `code-8vr0` (P1)
**Status:** Blocked on upstream — NVIDIA has not published Ubuntu 26.04 driver images yet

## Summary

`nvidia-driver-daemonset-sg22g` on k8s-node1 went into CrashLoopBackOff
with 76+ restarts. Root cause: k8s-node1 was upgraded to **Ubuntu 26.04
LTS (Resolute Raccoon)** at some point, putting the running kernel at
`7.0.0-15-generic`. The NVIDIA driver daemonset's installer container
runs `apt-get install linux-headers-<kernel>` against Ubuntu 24.04's
noble repositories (the container's base OS), which don't carry
`linux-headers-7.0.0-15-generic`, so the build aborts with:

    Could not resolve Linux kernel version

Attempted fix (chart upgrade v25.10.1 → v26.3.1 with driver 580.105.08
and `kernelModuleType: open`) succeeded at the chart level but produced
a worse outcome: the v26.3.1 operator auto-detects the host OS via NFD
and constructs the image tag `<version>-ubuntu26.04`, which 404s on
pull. `skopeo list-tags docker://nvcr.io/nvidia/driver` confirms zero
ubuntu26.04 tags exist (vs 779 ubuntu22.04 and 206 ubuntu24.04 tags).

Rolled the chart back to v25.10.1 (pinned in TF) to restore the closest-
to-working state pending an upstream fix or kernel rollback.

## Impact

- GPU resource `nvidia.com/gpu` = 0 on k8s-node1 (only GPU node)
- All GPU-bound workloads Pending or 0/N Ready:
  - `frigate/frigate`
  - `immich/immich-machine-learning`
  - `llama-cpp/llama-swap`
  - `nvidia/nvidia-exporter`
  - `ytdlp/yt-highlights`
- Downstream alerts firing: `NvidiaExporterDown`, 5× Uptime Kuma monitors
  (Frigate, Immich ML, nvidia-exporter, …), `GPUNodeUnschedulable` not
  firing (node is schedulable, just no GPU advertised)
- No data loss; no user-facing service degradation outside the GPU stack

## Timeline (Europe/Sofia, UTC+3)

- pre-incident — `apt-get dist-upgrade` (or `do-release-upgrade`) bumped
  k8s-node1 from Ubuntu 24.04 → 26.04. Apt history.log doesn't capture
  the upgrade (rotated by `do-release-upgrade`).
- ~2026-05-11 — node rebooted into kernel `7.0.0-15-generic`. NFD
  reports `system-os_release.VERSION_ID = 26.04`,
  `kernel-version.full = 7.0.0-15-generic`.
- 2026-05-17 04:00 (approx) — driver daemonset enters CrashLoopBackOff
  on every kubelet restart cycle. Error: "Could not resolve Linux kernel
  version".
- 2026-05-17 13:35 — chart upgrade attempt v25.10.1 → v26.3.1, driver
  570.195.03 → 580.105.08, `kernelModuleType: open`. Helm applies
  cleanly but driver pod ImagePullBackOff on
  `driver:580.105.08-ubuntu26.04`.
- 2026-05-17 ~13:45 — skopeo confirms zero ubuntu26.04 tags on
  nvcr.io/nvidia/driver. Decision: roll chart back, pin in TF, document
  the gotcha, file the kernel rollback as the next step.

## Root Causes

1. **Host OS upgraded to Ubuntu 26.04** ahead of NVIDIA's driver image
   support window. NVIDIA typically lags new Ubuntu LTS releases by
   weeks-to-months on the driver-container front.
2. **gpu-operator chart was not pinned** prior to today. The TF
   `helm_release` had `version` commented out, so any apply could
   re-resolve to the latest chart and follow its OS-auto-detection
   logic. With v25.10.1, the operator fell back to ubuntu24.04 image
   suffix (which pulls successfully but fails to compile against kernel
   7.0). With v26.3.1, the operator picks the correct (per-NFD)
   ubuntu26.04 suffix — which doesn't exist.
3. **No alert for "GPU device count = 0 on a GPU node"** — the cluster
   had 14+ hours of silent GPU outage before noticing. `NvidiaExporterDown`
   fires only when the metrics exporter itself stops scraping, not when
   the operator's driver pod is unhealthy.

## What We Changed in This Session

- `stacks/nvidia/modules/nvidia/main.tf` — pinned
  `helm_release.nvidia-gpu-operator.version = "v25.10.1"` so future
  applies don't surprise us with v26.3.1's stricter OS detection.
- `stacks/nvidia/modules/nvidia/values.yaml` — comment block explaining
  the situation; driver version stays at `570.195.03` as the last-known
  config that produced a pullable image.
- `docs/post-mortems/2026-05-17-gpu-driver-ubuntu2604-mismatch.md` —
  this file.

## What We Did NOT Do (Pending User Decision)

- **Roll back the host kernel** on k8s-node1 from `7.0.0-15-generic`
  to `6.8.0-117-generic`. The 6.8 kernel is still installed at
  `/lib/modules/6.8.0-117-generic` and the matching headers at
  `/usr/src/linux-headers-6.8.0-117-generic`, so GRUB can boot it and
  the driver image's apt sources (Ubuntu 24.04 noble) carry
  `linux-headers-6.8.0-117-generic`. This would require draining the
  node, editing GRUB defaults, `apt-mark hold` to prevent future drift,
  and rebooting — needs explicit user OK.
- **Add a probe + alert** for `nvidia.com/gpu` resource count on the
  GPU node. Should fire within 10 minutes of the operator failing to
  publish the resource, regardless of which sub-pod failed.

## Recovery Procedure (next time)

### If the driver-installer fails with "Could not resolve Linux kernel version"

1. Identify the running kernel: `uname -r` on the affected node.
2. Check whether NVIDIA ships an image for that kernel/distro combo:

       docker run --rm quay.io/skopeo/stable list-tags \
           docker://nvcr.io/nvidia/driver \
         | python3 -c "import json,sys; d=json.load(sys.stdin); \
             print([t for t in d['Tags'] if '<distro>' in t][:5])"

3. If yes, point the chart at the right version + ensure NFD reports
   the matching OS.
4. If no (and a kernel rollback is acceptable):
   - `kubectl cordon <node>` then `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data`
   - `nsenter -t 1 -m -p -u sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux 6.8.0-117-generic"/' /etc/default/grub`
   - `nsenter -t 1 -m -p -u update-grub`
   - `nsenter -t 1 -m -p -u apt-mark hold linux-image-6.8.0-117-generic linux-headers-6.8.0-117-generic linux-generic linux-image-generic linux-headers-generic`
   - Reboot: `nsenter -t 1 -m -p -u systemctl reboot`
   - After boot: `kubectl uncordon <node>` and wait for the GPU
     daemonset to come Ready

## Action Items

- [x] Pin gpu-operator chart to v25.10.1 in TF
- [x] Document situation in this post-mortem
- [ ] Roll back k8s-node1 host kernel to 6.8.0-117-generic + apt-mark
      hold (needs user authorization for node reboot)
- [ ] Add Prometheus alert `GPUNodeNoGPUResource` — fires when a node
      labeled `nvidia.com/gpu.present=true` has `nvidia.com/gpu` capacity
      of 0 for >10m
- [ ] Periodically re-check NVIDIA's NGC catalog for ubuntu26.04 driver
      tags — file as a quarterly checkup once we see the first 26.04
      tag, unpin the chart and revert this post-mortem's mitigation
- [ ] Audit ALL host packages with `apt-mark hold` semantics. The
      memory of the March 2026 outage says we disabled
      `unattended-upgrades` — `do-release-upgrade` is a separate path
      that should be gated too

## Lessons

- **Operator-style charts that auto-detect host OS can silently break
  when the host fleet leapfrogs upstream image support.** Pin the chart
  version + driver version, and treat upstream support gaps as a hard
  blocker rather than a guaranteed-to-resolve race condition.
- **Drain-and-revert host kernel is the right escape hatch when
  upstream image lags.** Make sure the previous kernel and its headers
  stay installed (don't aggressively purge old kernels in apt
  autoremove).
- **NFD labels are authoritative for the operator's image-tag
  construction.** If you need to lie about OS version (e.g., to force a
  24.04 image on a 26.04 host), edit the NFD label — but only as a last
  resort; the chart upgrade made clear the operator will eventually
  reconcile this.
