# Runbook: kube-apiserver Audit Logging

**Status:** enabled 2026-06-06 on `k8s-master` (10.0.20.100, the single
control-plane node). Motivated by the novelapp incident — a workload was
deleted with no way to attribute it, because apiserver audit logging had never
been on (see post-incident note below).

## What is configured

- **Audit policy:** `infra/scripts/k8s-apiserver-audit-policy.yaml` (source of
  truth), deployed to `/etc/kubernetes/audit-policy.yaml` on k8s-master.
  Low-write by design: drops reads (get/list/watch), high-churn resources
  (events, leases, endpointslices, token/subjectaccess reviews), and probe
  URLs; logs everything else (create/update/patch/delete) at **Metadata**
  level (who/verb/resource/namespace/name/time/sourceIP — no bodies).
  `omitStages: [RequestReceived]` → one line per mutating request.
- **kube-apiserver static-pod manifest** (`/etc/kubernetes/manifests/kube-apiserver.yaml`):
  `--audit-policy-file=/etc/kubernetes/audit-policy.yaml`,
  `--audit-log-path=/var/log/kubernetes/audit/audit.log`,
  `--audit-log-maxage=30 --audit-log-maxbackup=10 --audit-log-maxsize=100`,
  plus the `audit-policy` (File, RO) and `audit-logs` (DirectoryOrCreate)
  hostPath volumes/mounts.
  **On-disk history is ~2.8 days, not 30.** Measured 2026-09-01: at ~415 MB/day
  the size cap rotates a 100 MB file every 6-7 hours (9 rotations in 55 h), so
  `maxbackup=10` is reached long before `maxage=30` matters. The 1 GB ceiling
  holds. Loki keeps 30 days, so the trail survives there; the on-node grep
  fallback below covers roughly three days. `--audit-log-maxbackup` is the knob
  if more on-node history is wanted (k8s-master `/` had 33 GB free of 59 GB).
- **Persistence across `kubeadm upgrade`:** the same flags + volumes are in the
  `kubeadm-config` ConfigMap (`kube-system`), `ClusterConfiguration.apiServer.{extraArgs,extraVolumes}`
  (v1beta4). Without this, a control-plane upgrade regenerates the manifest and
  silently drops audit (and oidc). The OIDC flags are recorded there too (see
  below).
- **Shipping to Loki:** the Alloy DaemonSet
  (`infra/stacks/monitoring/modules/monitoring/alloy.yaml`) tails
  `/var/log/kubernetes/audit/audit.log` (it schedules on the control-plane node
  and mounts host `/var/log`). Query in Loki/Grafana with
  `{job="kubernetes-audit"}`.

## Two policy files, and only one is live

`stacks/rbac/modules/rbac/audit-policy.tf` writes a *different* audit policy to
a *different* path, and the apiserver never reads it. Measured 2026-09-01:

| | Path | Read by the apiserver? |
| --- | --- | --- |
| this runbook's policy | `/etc/kubernetes/audit-policy.yaml` | yes, `--audit-policy-file` points at it |
| the Terraform resource | `/etc/kubernetes/policies/audit-policy.yaml` | no |

The Terraform version also disagrees on the log path
(`/var/log/kubernetes/audit.log`) and the rotation flags (`maxage=7`,
`maxbackup=3`), and its rules *would* have logged `get`/`list` at Metadata level.
It has a `# THIS RESOURCE IS INERT` header as of 2026-09-01 and was deliberately
left alone: its `triggers` are content hashes, so changing them re-runs an SSH
provisioner that rewrites the apiserver manifest and restarts the API on the
single control-plane node, and CI applies that stack with no SSH key.

## Reads are not audited, and what that costs to change

Rule 1 of the live policy is `level: None` on `get, list, watch`, so **no
Kubernetes read is recorded anywhere**. Over 6 hours on 2026-09-01 the audit log
held 74,060 events (40,353 update, 21,368 create, 10,082 delete, 2,257 patch)
and zero reads, while the apiserver served 366,219 read requests. "Who read this
Secret" has no answer today.

Auditing Secret reads would cost about +147 MB/day (+36% on audit volume, +4.2%
on Loki's 3.54 GB/day cluster-wide ingest) and would shorten on-node history from
~2.8 to ~2.1 days. It lands on the master's local disk and in Loki, never in
etcd. Full sizing, the narrower `get`-only variant, and why Metadata level
answers less than it sounds like:
`docs/runbooks/apiserver-oidc-agent-identity.md` → "The audit read gap".

## How to attribute a change ("who deleted X, when")

```
# In Loki (Grafana Explore or logcli), last 24h:
{job="kubernetes-audit"} |= "delete" |= "<resource-name>"
```
Each entry is a JSON `audit.k8s.io/v1` Event: `user.username`, `verb`,
`objectRef.{resource,namespace,name}`, `requestReceivedTimestamp`,
`sourceIPs`, `userAgent`. On-node fallback (Loki down):
`sudo grep <name> /var/log/kubernetes/audit/audit.log` on k8s-master.

Note: direct `kubectl`/dashboard calls now show the real identity (user SA or
OIDC email). Pre-2026-06-06 deletions are NOT recoverable (audit was off).

## CRITICAL gotcha that blocked this (and OIDC) for weeks

`kubelet` runs **every** non-dotfile in its `staticPodPath`
(`/etc/kubernetes/manifests`) as a static pod. A stray
`kube-apiserver.yaml.bak.<epoch>` left in that directory (from an earlier manual
edit) was a **second** manifest defining pod `kube-apiserver`. kubelet ran the
older `.bak` copy and ignored edits to the real `kube-apiserver.yaml` — so newly
added flags (the OIDC flags, then these audit flags) never reached the running
process even though the file clearly had them. Symptom: the running apiserver's
`/proc/<pid>/cmdline` (or `crictl inspect` args) is SHORTER than the manifest's
`command:` list. Fix: move any `*.bak`/backup OUT of `/etc/kubernetes/manifests/`.
**Always back up control-plane manifests to a sibling dir (e.g.
`/etc/kubernetes/`), never inside `manifests/`.** This also un-blocked OIDC
(memory id=4042) as a side effect.

## Rollback

Backups live in `/etc/kubernetes/apiserver-manifest-archive/` on k8s-master
(the 27-arg pre-audit known-good, and the 36-arg desired). To disable audit:
remove the `--audit-*` flags + audit volumes from the manifest (kubelet
restarts the apiserver in ~30-40s), and remove them from `kubeadm-config`. A bad
manifest edit only needs the known-good copied back over
`/etc/kubernetes/manifests/kube-apiserver.yaml`.

Editing the apiserver manifest restarts the apiserver → ~30-40s API blip on this
single-control-plane cluster. Always edit from a backup + watch
`curl -sk https://10.0.20.100:6443/livez` before declaring success.
