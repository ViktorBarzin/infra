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
  `--audit-log-maxage=30 --audit-log-maxbackup=10 --audit-log-maxsize=100`
  (≤1 GB on disk, 30-day rotation), plus the `audit-policy` (File, RO) and
  `audit-logs` (DirectoryOrCreate) hostPath volumes/mounts.
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
