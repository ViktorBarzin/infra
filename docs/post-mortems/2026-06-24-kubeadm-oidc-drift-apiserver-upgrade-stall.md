# Post-mortem: kubeadm-config OIDC drift crash-looped the v1.35 apiserver upgrade (2026-06-24)

**Impact:** The autonomous k8s-version-upgrade chain (23:00 UTC nightly) reached
the master control-plane phase for the first time — preflight passed, etcd
snapshot taken, master cordoned + drained, etcd upgraded 3.6.5→3.6.6 — then the
kube-apiserver upgrade to v1.35.6 **crash-looped**. kubeadm waited its 5-minute
static-pod-hash window across all internal retries, then auto-rolled-back to
v1.34.9. The cluster stayed healthy on 1.34.9 (apiserver, all 7 nodes Ready), but
the run left **k8s-master cordoned** and the chain **wedged on `in_flight=1`**
(which correctly blocks subsequent runs). No data loss; no user-facing outage
(the master carries control-plane taints, so no workloads were displaced).

**Trigger:** the first *minor* upgrade the chain ever attempted (1.34→1.35).
Patch upgrades never hit this because the apiserver manifest content is identical
across patches; a minor upgrade is the first time kubeadm regenerates the
manifest with a new image.

## Root cause

apiserver authentication was configured in **two** places that were allowed to
drift from a **third**:

1. `/etc/kubernetes/pki/auth-config.yaml` — a structured `AuthenticationConfiguration`
   (apiserver.config.k8s.io/v1) carrying **two** JWT issuers (`kubernetes` for
   kubectl/kubelogin + `k8s-dashboard` for the dashboard's oauth2-proxy), added
   2026-06-19 (`docs/plans/2026-06-04-k8s-dashboard-sso-design.md`).
2. the **live** kube-apiserver static-pod manifest — referenced it via
   `--authentication-config=/etc/kubernetes/pki/auth-config.yaml`.
3. the **kubeadm-config `ClusterConfiguration` ConfigMap** — still carried the
   **legacy single-issuer `--oidc-*` extraArgs** (`oidc-issuer-url`,
   `oidc-client-id`, `oidc-username-claim`, `oidc-groups-claim`). Never updated
   when (1)+(2) switched to structured auth.

`kubeadm upgrade apply` **regenerates the static-pod manifests from
kubeadm-config**. So it dropped `--authentication-config` and re-added the four
`--oidc-*` flags. Proven by `kubeadm upgrade diff v1.35.6`:

```diff
-    - --authentication-config=/etc/kubernetes/pki/auth-config.yaml
+    - --oidc-issuer-url=https://authentik.viktorbarzin.me/application/o/kubernetes/
+    - --oidc-client-id=kubernetes
+    - --oidc-username-claim=email
+    - --oidc-groups-claim=groups
```

The regenerated apiserver crash-looped (`CrashLoopBackOff`, `back-off 10s`, 8
probe failures in the kubelet journal) — it exited within seconds, repeatedly, so
kubeadm's hash-watch never saw a stable new pod and timed out → rollback. (The
`--oidc-*` flags are NOT removed in 1.35; the crash is the auth-config swap in the
live control-plane environment, the only functional delta in the diff. Image
pull, etcd, OOM, and disk were all ruled out: all v1.35.6 images were pre-pulled,
etcd upgraded cleanly, no OOM, master root disk at 73%.)

**Why the existing safety net missed it:** `stacks/rbac/modules/rbac/apiserver-oidc.tf`
already *knew* kubeadm drops `--authentication-config` and published a
`apiserver-oidc-restore` ConfigMap for the chain to re-run **after** the upgrade.
But the apiserver crashes *during* `kubeadm upgrade apply`, which never returns
success, so the post-upgrade restore step is never reached.

## Resolution

1. **Reconciled kubeadm-config live** (2026-06-24, zero cluster impact — the CM is
   only read during an upgrade): rewrote `apiServer.extraArgs` to drop the
   `--oidc-*` args and add `--authentication-config`, via `kubeadm init phase
   upload-config kubeadm`. `kubeadm upgrade diff v1.35.6` then showed **only** the
   control-plane image bumps — no auth-flag changes.
2. **Recovered:** uncordoned k8s-master, cleared the stuck `in_flight` gauge +
   namespace annotation.

## Prevention (all landed in this change)

| Gap | Fix |
|-----|-----|
| kubeadm-config not managed alongside the live manifest | `apiserver-oidc.tf`'s remote script now **also** reconciles kubeadm-config (`kubeadm init phase upload-config`). It reaches the cluster two ways: the published `apiserver-oidc-restore` ConfigMap (a plain k8s resource — CI applies it with no ssh) which the chain's `phase_master` re-runs, and a local `-replace` apply with `TF_VAR_ssh_private_key`. (The null_resource trigger deliberately does NOT hash the script: CI has no ssh key, so it must stay a no-op on a plain CI apply.) |
| The chain drained the master into a crash with no pre-check | new **preflight gate 4b** in `upgrade-step.sh`: runs `kubeadm upgrade diff v$TARGET` and `block`s (k8s_upgrade_blocked=1 → K8sUpgradeBlocked alert) BEFORE snapshot/in-flight/drain if a `-` line would drop `--authentication-config`. Fails safe — blocks only on a positive drift signal. |
| The live fix had to be applied out-of-band (only `default` Vault policy on the workstation; CI can't ssh) | kubeadm-config reconciled live via `kubeadm init phase upload-config` on the master (2026-06-24); the committed code makes it durable for future upgrades. |

## Lessons

- **Out-of-band control-plane edits must be written back to kubeadm-config.**
  Anything that edits a static-pod manifest directly (auth, admission, audit, API
  flags) is silently reverted on the next `kubeadm upgrade` unless kubeadm-config
  itself carries it. `kubeadm upgrade diff <target>` is the authoritative
  pre-flight check for "what will the upgrade change?" and is non-mutating.
- **A post-upgrade fixup can't repair something that breaks the upgrade itself.**
  The restore-after-upgrade design assumed the apiserver would come up (degraded)
  and be fixed afterward; it actually crash-looped, so the fix has to be in
  kubeadm-config *before* `apply`, plus a preflight gate.
- **Minor upgrades exercise manifest regeneration; patch upgrades don't.** First
  minor bump is where this whole class of drift surfaces.
