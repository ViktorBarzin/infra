# Post-Mortem: nfs-csi Keel-Triggered Upgrade Broke Master Node CSI

**Date:** 2026-05-17
**Author:** Viktor Barzin / Claude (incident response)
**Severity:** SEV-3 (1 of 5 CSI node DaemonSet pods stuck CrashLoopBackOff; controller pair flapping)
**Duration:** ~2 hours from first detection to all-green

## Summary

The Keel auto-update operator polled the `csi-driver-nfs` Helm chart and rolled
`v4.13.1 → v4.13.2`. The new chart's controller Deployment scheduled both
replicas onto `k8s-master` (no built-in control-plane exclusion). Both replicas
used `hostNetwork: true` and tried to bind the same host ports
(`19809` for `node-driver-registrar`, `29653` for `liveness-probe`), so one
controller pod CrashLoopBackOff'd with `bind: address already in use`. The
upgrade also left behind multiple orphan controller pods in containerd that
kubelet could no longer reconcile — they held the host ports even after the
helm rollback removed them from K8s state.

The `csi-nfs-node` DaemonSet pod on master then could not start either: its
own `node-driver-registrar` and `liveness-probe` containers tried to bind
the same host ports and lost to the zombies.

## Impact

- 1× `csi-nfs-node` pod on `k8s-master` stuck CrashLoopBackOff (16+ restarts)
- CSI plugin unregistered on master → no NFS volumes could be mounted on
  master-hosted pods (calico-typha cert mount failed, etcd backup CronJob
  failed)
- Controller flap (2 replicas fighting) → intermittent
  `csi-resizer`/`csi-snapshotter` failure for the whole cluster
- Cascade: kured-sentinel, node-local-dns, prometheus-node-exporter,
  csi-node-driver (Calico) all bounced on master while kubelet thrashed

No data loss; no production-facing outages observed (CSI mounts on the four
worker nodes kept working).

## Timeline (Europe/Sofia, UTC+3)

- ~07:46 — Keel polls forgejo + DockerHub manifests, sees a new digest under
  the `csi-driver-nfs` `4.13.x` channel, triggers Helm upgrade
- 07:46:16 — `helm upgrade csi-driver-nfs` runs; new controller Deployment
  scheduled (no `affinity` block → both replicas land on `k8s-master`)
- ~07:50 — Controller replicas fight for ports `19809`, `29653`; one stays in
  CrashLoopBackOff
- ~08:00 — User notices "CSI issue ... due to the upgrade"; investigation
  begins
- 08:15 — `helm rollback csi-driver-nfs` to revision 8 (v4.13.1) — controllers
  on master deleted via K8s, but containerd retains them as live sandboxes
- 08:30 — Live `podAntiAffinity` + `nodeAffinity: control-plane DoesNotExist`
  added to the controller Deployment via patch (controllers now correctly
  schedule on node1+node3)
- 08:40 — `csi-nfs-node` master pod still CrashLoopBackOff; ports 19809/29653
  held by orphan PIDs (livenessprobe PID 1816, csi-node-driver PID 1944,
  plus 5× csi-provisioner from zombie controller pods)
- 09:00 — Privileged pkill via `hostPID: true` pod failed
  (`permission denied` from runc — containerd refused to signal init in the
  zombie containers)
- 09:03 — `nsenter -t 1 -m -p -u systemctl restart kubelet` on master cleared
  the orphan containers via cgroup GC; ports freed
- 09:04 — `csi-nfs-node` master pod reaches 3/3 Ready; cluster green
- 09:09 — Terraform `apply`: pin `helm_release.version = "4.13.1"`, add
  `controller.affinity` to values

## Root Causes

1. **`csi-driver-nfs` Helm chart in TF was unpinned.** The `helm_release` had
   no `version = ...` field, so it floated to whatever the chart repo
   advertised. Keel polled this and rolled forward.
2. **Chart v4.13.2 dropped the implicit control-plane exclusion** that v4.13.1
   shipped with. Without it, the K8s scheduler chose master for both
   controller replicas.
3. **Two controller replicas + hostNetwork = port conflict on the same node.**
   The chart did not add `podAntiAffinity` between the replicas. Live state
   has it now; TF now does too.
4. **Helm rollback does not always clean containerd sandboxes.** When the
   prior revision's pods are abandoned mid-flight (image-pull-pending, etc.),
   containerd can keep multiple sandbox instances for the same pod-UID.
   Kubelet GC is the only thing that reliably reaps these — restarting it
   forces a reconciliation pass that drops orphans.

## What We Fixed

- **`stacks/nfs-csi/modules/nfs-csi/main.tf`** (this commit):
  - `version = "4.13.1"` pin on the `helm_release` (defense in depth — namespace
    is already excluded from Kyverno-Keel injection, but the chart could still
    drift on a `terraform apply` without a pin)
  - `controller.affinity` block with `podAntiAffinity` (different hosts for
    replicas) and `nodeAffinity` (exclude `node-role.kubernetes.io/control-plane`)
  - Inline comments explaining both decisions
- **Kyverno keel-annotations**: `nfs-csi` was already in the namespace exclude
  list (decision from authentik incident 2026-05-17). Verified still there
  in `stacks/kyverno/modules/kyverno/keel-annotations.tf:91`.

## Recovery Procedure (next time)

If `csi-nfs-node` on a node CrashLoopBackOff with `bind: address already in use`:

1. **Find which host ports are bound** — `lsof -i :19809`, `lsof -i :29653`
   (from a privileged hostPID pod on the affected node).
2. **Try `crictl rmp -f <pod-id>`** on zombie pods (those K8s no longer
   tracks). Will fail with `unable to signal init: permission denied` if
   the containers are sufficiently stuck.
3. **Restart kubelet on the affected node** via `nsenter -t 1 -m -p -u
   systemctl restart kubelet` (privileged hostPID pod). Kubelet's GC
   reconciles containerd state and reaps the orphans.
4. **Force-delete the DaemonSet pod** to clear the back-off
   (`kubectl delete pod -n nfs-csi csi-nfs-node-XXXX --force --grace-period=0`).
   DaemonSet recreates it; with the ports free, containers start cleanly.

## Action Items

- [x] Pin `csi-driver-nfs` chart version in TF
- [x] Add `controller.affinity` to TF (podAntiAffinity + control-plane exclude)
- [x] Document recovery procedure (this post-mortem)
- [ ] Audit other unpinned `helm_release` blocks — every chart used in
      Kyverno-excluded namespaces should still be pinned to prevent
      `terraform apply` drift. (Filed as follow-up — not blocking.)
- [ ] Consider adding a `kured` or daily script that detects orphan
      containerd sandboxes whose pod-UID is unknown to the apiserver and
      reaps them automatically. (Filed as follow-up — not blocking.)

## Lessons

- **Keel exclusion ≠ chart pin.** The namespace was already excluded from
  Keel injection, but the helm_release was unpinned — so a `terraform apply`
  alone could re-trigger the same break. Both layers needed locking down.
- **`crictl rmp -f` is not always sufficient.** When containerd refuses to
  signal init, kubelet restart is the next escalation step before SSH/reboot.
- **The Keel rollout phase 2-6 design ASSUMED stateful operators were
  excluded.** CSI was correctly excluded — but the chart version itself was
  still a moving target via plain `terraform apply`. The exclude-list catches
  Keel; the version pin catches everything else.
