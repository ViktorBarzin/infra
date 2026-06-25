# Post-mortem: k8s 1.34→1.35 upgrade stalled — etcd IO starvation (2026-06-24)

> Filename kept for inbound links. The originally-suspected cause (kubeadm-config
> OIDC drift) turned out **not** to be the crash — see "Correction" below. The OIDC
> drift was a real *separate* latent bug fixed in the same change.

**Impact:** The autonomous k8s-version-upgrade chain (23:00 UTC nightly) reached
the master control-plane phase for the first time — preflight passed, etcd
snapshot taken, master cordoned + drained, etcd upgraded 3.6.5→3.6.6 — then the
kube-apiserver upgrade to v1.35.6 **crash-looped**. kubeadm waited its 5-minute
static-pod-hash window across all internal retries, then auto-rolled-back to
v1.34.9. The cluster stayed healthy on 1.34.9 (apiserver, all 7 nodes Ready), but
the run left **k8s-master cordoned** and the chain **wedged on `in_flight=1`**.
No data loss; no user-facing outage (the master carries control-plane taints, so
no workloads were displaced).

**Trigger:** the first *minor* upgrade the chain ever attempted (1.34→1.35) — the
first time kubeadm upgrades etcd (3.6.5→3.6.6) and regenerates the control-plane
static pods, i.e. the first time the upgrade pushes real write-IO at etcd.

## Root cause — etcd IO starvation on the shared HDD

The new kube-apiserver could not establish/keep a working connection to etcd
during the upgrade because **etcd was IO-starved**. etcd's surviving container log
from the crash window (`/var/log/pods/.../etcd/0.log`, 23:04–23:20 UTC) shows:

- **1,180** `apply request took too long` warnings in 16 minutes;
- individual applies of **4.3s / 2.9s / 2.7s / 1.8s** (healthy is <100ms),
  clustered at **23:18:51 UTC** — exactly when kubeadm's final attempt was trying
  to bring the new apiserver up.

A reproduced 1.35.6 apiserver with no etcd dies with
`F instance.go:233 Error creating leases: error creating storage factory: context
deadline exceeded` — the same failure mode a multi-second etcd produces. etcd
lives on the contended `sdc` HDD (**beads code-oflt**: "etcd/critical VM disks on
shared sdc HDD — recurring IO-storm root cause"). The upgrade itself piled IO onto
that spindle:

1. etcd's own upgrade-restart + WAL/db re-read (it restarted ~23:04, re-elected);
2. kubeadm dumping a full **~400MB etcd DB backup** to
   `/etc/kubernetes/tmp/kubeadm-backup-etcd-<ts>/` (on the same HDD) before the
   etcd upgrade — and **145 of these had accumulated to 28GB** (kubeadm never
   cleans them up), pushing master root fs to **73%**, above the 70% kubelet
   image-GC threshold, so image GC churned during the drain too;
3. master-drain pod evictions.

### Correction — it was NOT the OIDC flag swap

`kubeadm upgrade diff v1.35.6` showed the regenerated manifest also swaps
`--authentication-config` (structured multi-issuer OIDC) back to legacy
single-issuer `--oidc-*` flags (kubeadm-config drift, see secondary finding). That
was the *first* hypothesis — but an isolated repro of the 1.35.6 apiserver with
those exact `--oidc-*` flags **and authentik reachable** initialised OIDC cleanly
(`oidc.go:313`, no error) and ran fine until it hit the (deliberately dead) test
etcd. So the auth swap does **not** crash the apiserver; it was a red herring for
the crash. Image pull (all v1.35.6 images pre-pulled), OOM (none), and disk-full
were also ruled out.

## Secondary finding (real, fixed separately) — kubeadm-config OIDC drift

apiserver auth is configured in three places that must agree:
(1) `/etc/kubernetes/pki/auth-config.yaml` (structured, two issuers: `kubernetes`
+ `k8s-dashboard`, added 2026-06-19); (2) the live static-pod manifest
(`--authentication-config`); (3) the kubeadm-config `ClusterConfiguration` CM —
which still carried the legacy `--oidc-*` extraArgs. `kubeadm upgrade` regenerates
the manifest from (3), so it would have reverted structured auth → **dashboard +
kubectl SSO break after a successful upgrade** (recoverable: the chain's
post-master `restore.sh` re-adds the flag). This is a real bug, just not the crash.

## Resolution

1. **Reclaimed the 28GB kubeadm scratch** on master (`/etc/kubernetes/tmp/kubeadm-backup-*`) — root fs 73% → 23%.
2. **Reconciled kubeadm-config live** (zero cluster impact — CM only read at upgrade time): dropped `--oidc-*`, added `--authentication-config` via `kubeadm init phase upload-config kubeadm`. `kubeadm upgrade diff` then shows only the control-plane image bumps.
3. **Recovered:** uncordoned k8s-master, cleared the stuck `in_flight` gauge + annotation, deleted last night's Complete/Failed `1-35-6` phase jobs (a Complete preflight would otherwise make the detector idempotent-skip the re-run).

## Prevention (landed in this change)

| Gap | Fix |
|-----|-----|
| kubeadm leaks ~400MB etcd-DB backups into `/etc/kubernetes/tmp` forever (→ disk fills, image-GC churn, write-IO on etcd's spindle) | **`upgrade-step.sh` preflight now prunes** `/etc/kubernetes/tmp/kubeadm-backup-*` + `kubeadm-upgraded-manifests*` older than 3 days on master, every run. Best-effort, never aborts. |
| kubeadm-config drift would silently break SSO after an upgrade | `apiserver-oidc.tf`'s remote script now **also reconciles kubeadm-config** (`kubeadm init phase upload-config`), delivered via the `apiserver-oidc-restore` ConfigMap the chain re-runs (CI needs no ssh) or a local `-replace` apply. Preflight **alerts** (not blocks — SSO drift is recoverable) if `kubeadm upgrade diff` would still drop `--authentication-config`. |
| etcd on the contended `sdc` HDD starves under upgrade IO | **Durable fix is beads code-oflt** (move etcd/critical VM disks off `sdc`). Not in this change. Mitigations above reduce the upgrade's own IO; reclaimed disk removes the image-GC variable. |

## Lessons

- **Capture the failing component's own logs before concluding.** The `kubeadm
  upgrade diff` made the OIDC swap look like the cause; only etcd's log (multi-second
  applies) + an isolated apiserver repro showed the truth (etcd IO). A clean diff is
  "what config changes," not "why it crashed."
- **etcd on shared HDD is the cluster's recurring fragility** (immich IO storm
  2026-05-25, this stall). Upgrades concentrate IO (etcd restart + kubeadm's 400MB
  backup copy + drain) onto that spindle. code-oflt is the real fix.
- **Tools that leave per-operation scratch must be reaped.** kubeadm's
  `/etc/kubernetes/tmp` etcd backups are throwaway (real backups → NFS) but never
  GC'd; 28GB had silently accumulated.
- **Out-of-band control-plane edits must be written back to kubeadm-config** — else
  `kubeadm upgrade` silently reverts them (here: SSO; could be admission/audit/API flags).
