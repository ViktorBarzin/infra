# HA Control Plane (3 masters) — Design

**Date**: 2026-05-21
**Status**: Drafted, NOT scheduled
**Beads**: code-n0ow
**Trigger**: today's k8s 1.34.7→1.34.8 autonomous-upgrade session repeatedly hit a storm cascade rooted in single-master apiserver outages

## Problem statement

The autonomous k8s upgrade pipeline (`stacks/k8s-version-upgrade/`) is
correct end-to-end but **cannot push through the cluster's
single-master architecture**. Each attempted upgrade today rolled
back via the same cascade:

1. Chain drains master → `kubeadm upgrade apply` swaps a static-pod
   manifest (etcd → apiserver → controller-manager → scheduler).
2. While a manifest swap is in flight, the affected control-plane
   component is briefly down — for apiserver, that means ~10–60s of
   "connection refused" to `10.96.0.1:443` from every kubelet and
   operator pod in the cluster.
3. **Several operators die during that window** instead of waiting:
   - **tigera-operator**: logs `[ERROR] Get "https://10.96.0.1:443/api?timeout=32s": connect: connection refused` then exits 1 immediately
   - gpu-operator, cnpg-cloudnative-pg, kube-controller-manager: similar leader-lease failures
4. Kubelet restarts those pods → image pulls + initial reads → storm
   of disk I/O on master (we observed 563 MB/s from tigera alone).
5. **The storm slows apiserver-to-kubelet status sync** past kubeadm's
   hardcoded 5-min watch on the pod's `kubernetes.io/config.hash`
   annotation.
6. kubeadm declares the upgrade "did not change after 5m0s",
   **rolls back to the previous manifest**, exits non-zero.
7. Chain Job retries (backoffLimit=1) → same storm → same failure.
   Chain dead.

The container runtime, the script logic, the RBAC permissions are all
fine after today's fixes. The **single master is the bottleneck**.

## Why HA control plane fixes this

With 3 masters running etcd quorum + apiserver behind an LB:

| Failure mode | Single master | 3-master HA |
|---|---|---|
| Master reboot / kubeadm upgrade | Apiserver completely down 10–60s | Other 2 masters serve clients; LB transparently fails over |
| etcd quorum during one master being down | Total outage (1/1 broken) | Quorum maintained (2/3 healthy) |
| Tigera/operators see apiserver as "down" | Yes → crashloop storm | No → keep running through |
| kubeadm `static-pod hash` watch | Times out under load (today's bug) | Never under load; sync stays fast |
| Pipeline upgrade success rate | Brittle / needs manual nursing | Truly autonomous |

The k8s upgrade chain doesn't need to be aware of *any* of this — the
underlying availability of apiserver makes the chain's gates
naturally pass on each iteration.

## Decisions (proposed — to be confirmed)

| # | Decision | Notes |
|---|----------|-------|
| 1 | **3 masters** (not 5) | Quorum tolerates 1 failure, sufficient for home-lab. 5 would tolerate 2 but doubles etcd write amplification. |
| 2 | **Sizing**: match current `k8s-master` (8 vCPU, 32GB RAM, ~64 GB disk) for all 3 | Symmetric. New VMs `k8s-master-2`, `k8s-master-3` on Proxmox. |
| 3 | **Apiserver LB**: **pfSense HAProxy** (existing pattern, see mailserver-pfsense-haproxy.md) over keepalived+haproxy-on-each-master | Pros: no per-node moving parts, mirrors the mailserver layout already in production. Cons: pfSense becomes more SPoF — but it's already SPoF for everything else (DNS, gateway, ingress). |
| 4 | **VIP**: pick an unused IP on the cluster VLAN, e.g. `10.0.20.99`, point all kubeconfigs + kubelet `--server` at it | Internal-only VIP; external API access stays via Cloudflared. |
| 5 | **etcd**: kubeadm-managed (existing); just `kubeadm join --control-plane` brings new members into the etcd cluster automatically | Avoids running etcd separately. |
| 6 | **kured-sentinel-gate**: extend "quorum-safe" check to verify ≥2 control-plane nodes Ready before allowing a reboot | Otherwise kured could reboot 2 masters at once and break quorum. |
| 7 | **etcd backup**: today's `etcd-backup` CronJob already takes a snapshot from one member; that's still sufficient (etcd snapshot is a consistent point-in-time). No new work needed. | |
| 8 | **Migration order**: add masters one at a time, run smoke (kubectl from each), then cut over kubeconfigs | Each `kubeadm join --control-plane` is reversible (just `kubeadm reset` + remove from etcd member list). |

## Out of scope

- HA pfSense itself (separate, much bigger initiative)
- Multi-DC failover
- External etcd cluster (we're sticking with kubeadm-managed stacked etcd)
- Rebuilding cluster from scratch — we'll join into the existing one

## Risk register

| Risk | Mitigation |
|---|---|
| etcd quorum split-brain during member join | kubeadm join is atomic; if it fails, the new member doesn't join the quorum. Existing etcd stays healthy. |
| LB misconfiguration → all kubectl breaks | Smoke-test from each master before flipping clients. Keep a kubeconfig pointing directly at one master as fallback. |
| Existing kubeconfigs (dev VM, agents, woodpecker) need updating | List all consumers, update in a single TF apply. |
| New masters get scheduled some workload pods unintentionally | Verify control-plane taint is applied at join time. |
| Cluster-wide cert rotation might be needed | kubeadm join handles certs automatically using the `--certificate-key` from `kubeadm init phase upload-certs`. |
| 32GB per master × 3 = 96GB RAM used for control plane alone | Proxmox host has headroom; not blocking. |

## Verification

After all 3 masters joined + LB up:

```bash
# All 3 masters listed
kubectl get nodes -l node-role.kubernetes.io/control-plane=

# etcd quorum healthy
kubectl -n kube-system exec etcd-k8s-master -- etcdctl \
    --endpoints=https://10.0.20.100:2379,https://10.0.20.X:2379,https://10.0.20.Y:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    endpoint health --cluster

# Failover test: cordon master-1, reboot it, observe kubectl still works through LB
kubectl drain k8s-master --delete-emptydir-data --ignore-daemonsets
ssh wizard@k8s-master.viktorbarzin.lan sudo reboot

# Pipeline test: re-trigger k8s upgrade chain (e.g. for whatever the next patch is)
kubectl -n k8s-upgrade create job --from=cronjob/k8s-version-check ha-validation-$(date +%s)
# Expect: full chain succeeds end-to-end without manual intervention
```

## Cost estimate

- 2× VMs at 8 vCPU + 32GB RAM each = +64GB RAM on Proxmox host
- ~+128GB disk usage (2× 64GB master disks)
- ~2-4 hours of operator time end-to-end (VM provisioning + kubeadm join + LB config + smoke)

## What's already in place from today's work

(All these are prerequisites that were fixed during today's
investigation — they stay relevant when HA lands.)

- Master containerd 1.6.22 → 2.2.2, runc 1.1.8 → 1.4.0 (fixed
  `runc: unable to signal init: permission denied` on Ubuntu 26.04)
- Pipeline script bugs: 3× `grep -vE` pipefail, 1× RBAC missing
  `get daemonsets`, 1× `RecentNodeReboot` not ignored in master phase
- Kill-switch ConfigMap mechanism (`k8s-upgrade-killswitch`)
- Kubeadm-apply retry wrapper in `update_k8s.sh` (helps but doesn't
  fully fix the storm cascade)
- Quiet-baseline threshold 3600s → 600s

## Reference

Commits from today's session:
- `10b261d2` — first `grep -vE` pipefail
- `0c8b46df` — 2 more pipefail sites
- `fc0510aa` — kill-switch + RecentNodeReboot ignore + 600s threshold
- `2dc7e001` — kubeadm apply 3-attempt retry
