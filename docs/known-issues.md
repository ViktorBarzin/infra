# Known Issues

Catalog of recurring or upstream-blocked failure modes with their
mitigations. Anything that requires a manual workaround should be
documented here — if a future session can hit the same issue, it
deserves an entry. Each entry should have: symptom, root cause, current
mitigation, and the trigger that lets us un-mitigate.

---

## 2026-05-17 — NVIDIA GPU driver fails on Ubuntu 26.04 (kernel 7.0.x)

**Symptom.** `nvidia-driver-daemonset-*` in `nvidia` namespace
CrashLoopBackOff on the GPU node. Logs say:

    Could not resolve Linux kernel version

… or, post chart-upgrade, ImagePullBackOff on a `*-ubuntu26.04` tag.

**Root cause.** NVIDIA has not published any `nvcr.io/nvidia/driver:*-ubuntu26.04`
images (0 tags as of 2026-05-17; verified with skopeo). When a k8s node
running the GPU operator gets `do-release-upgrade`'d to Ubuntu 26.04
Resolute Raccoon, NFD relabels the node with
`feature.node.kubernetes.io/system-os_release.VERSION_ID=26.04` and the
operator computes the driver image tag `<version>-ubuntu26.04` — which
404s on pull. Both gpu-operator chart v25.10.1 and v26.3.1 exhibit the
same behaviour once NFD has detected 26.04.

**Current mitigation (active on k8s-node1 since 2026-05-17).**

1. Host kernel rolled back to `6.8.0-117-generic` (Ubuntu 24.04 HWE
   kernel — still installed at `/lib/modules/6.8.0-117-generic`).
2. `apt-mark hold` on: `linux-image-6.8.0-117-generic`,
   `linux-headers-6.8.0-117-generic`, `linux-modules-6.8.0-117-generic`,
   `linux-image-generic`, `linux-headers-generic`, `linux-generic`.
3. `/etc/os-release` on k8s-node1 replaced with the Ubuntu 24.04 Noble
   content (was a symlink to `/usr/lib/os-release`; now a regular file
   under `/etc`). Backup at `/etc/os-release.bak-pre-spoof-2026-05-17`.
   NFD-worker reads `/etc/os-release` and now reports
   `system-os_release.VERSION_ID=24.04`, so the operator picks the
   matching ubuntu24.04 driver image which DOES exist.
4. gpu-operator chart pinned to v25.10.1 in
   `stacks/nvidia/modules/nvidia/main.tf`; driver pinned to 570.195.03
   in `stacks/nvidia/modules/nvidia/values.yaml`.

**This is gross but stable.** The kernel matches what 24.04 ships, and
the `apt-mark hold` keeps it that way. /etc/os-release lying about the
OS only affects userland callers that key off it — none of our
deployed services do (we verified by grepping the cluster).

**Trigger to un-mitigate.** Periodically check for ubuntu26.04 driver
tags. Once they appear:

    docker run --rm quay.io/skopeo/stable list-tags \
        docker://nvcr.io/nvidia/driver \
      | python3 -c "import json,sys; d=json.load(sys.stdin); \
          print(len([t for t in d['Tags'] if 'ubuntu26.04' in t]))"

When that returns a non-zero count:

1. Restore `/etc/os-release` from backup
    (`/etc/os-release.bak-pre-spoof-2026-05-17`) on k8s-node1.
2. Remove apt-mark holds for the kernel packages.
3. `apt full-upgrade` to land the latest 26.04 kernel + reboot.
4. Bump the gpu-operator chart pin to the matching version that ships
   ubuntu26.04 driver images. Bump `driver.version` in values.yaml to
   the current chart default.

**See also.** `docs/post-mortems/2026-05-17-gpu-driver-ubuntu2604-mismatch.md`
for full incident timeline + the recovery procedure.

**Beads.** `code-8vr0` (P1, OPEN).
