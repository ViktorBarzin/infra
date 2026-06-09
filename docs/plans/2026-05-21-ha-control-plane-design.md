# HA Control Plane (3 masters) — Design

**Date**: 2026-05-21 (decisions locked 2026-05-22; **deferred 2026-05-23**)
**Status**: **DEFERRED** — design + plan complete, NOT scheduled. Awaiting either PVE host capacity expansion OR a separate right-sizing pass on the existing master before this becomes affordable. Paired plan: `2026-05-21-ha-control-plane-plan.md`.
**Beads**: code-n0ow (open, deferred — see `bd show code-n0ow`)
**Trigger**: 2026-05-21 k8s 1.34.7→1.34.8 autonomous-upgrade session repeatedly hit a storm cascade rooted in single-master apiserver outages

## Why deferred (2026-05-23)

Measured during the locking pass:

- **k8s-master uses 4.6 GB of 32 GB allocated** (kube-apiserver 2.6 GB + etcd 660 MB + cm 360 MB + ~1 GB everything else). The 32 GB sizing is ~5-6× oversized vs working set.
- **PVE host is already 98% RAM-committed** — 262 GB allocated to VMs against 267 GB physical, with 1.5 GB of active swap. The planned 3 × 32 GB control plane (+64 GB net) would push allocation to 326 GB → OOM on the host.
- **Software-only HA on a single PVE host has bounded value** — a hypervisor crash still loses all 3 masters. The big resilience wins (kubeadm upgrades, cert rotation, planned reboots) are real but the disaster-recovery angle is limited until a second PVE host exists.

### Revisit triggers — any of:

1. **Second PVE host added** to the lab. Hardware HA becomes possible; HA control plane becomes the natural follow-up. Spread the 3 masters across 2 hosts (2+1).
2. **Cluster-wide right-sizing pass** that frees enough headroom for the original 3 × 32 GB plan, OR pre-agreed amendment to provision 16 GB masters (right-sized to actual usage; 3-4× current working-set headroom).
3. **Storm cascade burns enough hours** that the operational cost outweighs the memory cost — track minutes spent manually nursing kubeadm upgrades; if cumulative > ~10h over a few months, revisit.

### What's still good

The design + plan in this directory remain authoritative. When we revisit:

- All 14 locked decisions stand.
- Challenger amendments (cloud-init template bump, rbac multi-master refactor, HTTPS `/readyz` health check, expanded blast radius, etcd-backup nodeSelector, chain extension as Phase 7) are baked in.
- Only the sizing decision needs revisiting — likely 16 GB per master instead of 32 GB.
- Adding `k8s_master_hosts` list-based refactor to the rbac stack (Phase 1.5) is a **standalone win** that could be done independently of HA — it would future-proof the cluster against the day HA lands. Consider lifting that as its own task.

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

## Decisions (locked 2026-05-22)

| # | Decision | Notes |
|---|----------|-------|
| 1 | **3 masters** (not 5) | Quorum tolerates 1 failure, sufficient for home-lab. 5 would tolerate 2 but doubles etcd write amplification. |
| 2 | **Sizing**: match current `k8s-master` (8 vCPU, 32GB RAM, ~64 GB disk) for all 3 | Symmetric. New VMs `k8s-master-2` (VMID 205, 10.0.20.110), `k8s-master-3` (VMID 206, 10.0.20.111). |
| 3 | **Apiserver LB**: **pfSense HAProxy** — new TCP frontend on `10.0.20.99:6443` mirroring the mailserver pattern. Idempotent via `scripts/pfsense-haproxy-bootstrap.php`. | Pros: no per-node moving parts, mirrors existing mailserver layout. Cons: pfSense becomes more SPoF — but it's already SPoF for everything else (gateway/DNS/ingress). |
| 4 | **VIP**: `10.0.20.99` (one below current master `.100`, well clear of MetalLB pool `.200-.220`). Internal-only — external API access stays via Cloudflared. | All kubeconfigs + kubelet.conf entries flip from `10.0.20.100:6443` → `10.0.20.99:6443`. |
| 5 | **etcd**: kubeadm-managed stacked; `kubeadm join --control-plane` brings new members into the etcd cluster automatically | Avoids running etcd separately. |
| 6 | **kured-sentinel-gate**: extend the bash loop in `stacks/kured/main.tf` with a "≥2 control-plane nodes Ready" check between the existing all-nodes-Ready and calico-Ready checks | Otherwise kured could reboot 2 masters at once and break quorum. |
| 7 | **etcd backup**: `etcdctl snapshot save` from any member is a consistent point-in-time of the full quorum state — but the existing CronJob is pinned `node_name = "k8s-master"`. Phase 4.5 flips this to a control-plane label + toleration so backups don't silently skip when master-1 is drained. | Snapshot CORRECTNESS unchanged; SCHEDULING needs fixing. |
| 8 | **Migration order**: Phase 0 (retrofit existing cluster) → Phase 1 (LB up, single backend, HTTPS health check) → Phase 1.5 (rbac stack refactor) → Phase 2 (cloud-init bump + master-2 join + add to LB) → Phase 3 (master-3 join + add to LB) → Phase 4 (flip clients + workers to VIP) → Phase 4.5 (etcd-backup CronJob fix) → Phase 5 (kured-sentinel-gate quorum check) → Phase 6 (E2E validation) → Phase 7 (k8s-version-upgrade chain extension) | Each kubeadm join is reversible (`kubeadm reset` + `etcdctl member remove`). |
| 9 | **VM provisioning**: cloud-init via `create-template-vm` module, **but the template needs an apt-source bump first** (v1.32 → v1.34) and a control-plane gate on `k8s_join_command` so master VMs don't auto-join as workers. Existing master stays as the legacy manual VM (not rebuilt). | The repo has zero VMs using cloud-init for provisioning today — we're the first user. Update template first, then use it. |
| 10 | **Cert SAN + controlPlaneEndpoint retrofit**: Phase 0, before any new master joins. Patch `kubeadm-config` via `kubeadm init phase upload-config kubeadm --config <file>` (kubeadm-owned write, future-proof against `kubeadm upgrade apply`), regen `apiserver.crt` via `kubeadm init phase certs apiserver`, restart the kube-apiserver pod (~30s outage on the existing master only). | Standard kubeadm retrofit path; `kubeadm join --control-plane` requires controlPlaneEndpoint to be set. |
| 11 | **Multi-master config propagation (Phase 1.5)**: refactor `stacks/rbac/modules/rbac/{apiserver-oidc,audit-policy,etcd-tuning}.tf` to loop over a list of master hosts. Apply BEFORE master-2/3 join so they boot with OIDC, audit policy, and etcd tuning already in place. | Today these stacks SSH into a single master and sed into `kube-apiserver.yaml` — if not propagated, Authentik login flaps depending on which master the LB lands on. |
| 12 | **k8s-version-upgrade chain extension (Phase 7)**: extend `stacks/k8s-version-upgrade/scripts/upgrade-step.sh` to discover and iterate over all control-plane nodes (drain → upgrade → uncordon, gated by quorum check). | Without this, chain only upgrades master-1; masters 2/3 drift behind one version per upgrade. Original autonomous-upgrades goal unmet. |
| 13 | **LB health check**: HTTPS `GET /readyz` (with `verify none` for self-signed apiserver cert), NOT plain TCP. | Plain TCP misses apiserver-NotReady states (etcd unreachable, controller-manager flapping). |
| 14 | **VIP DNS name**: add `k8s-apiserver IN A 10.0.20.99` to `config.tfvars` BEFORE Phase 4. Delete stale `kubernetes IN A 10.0.20.100`. Consumers reference the FQDN, not the bare IP — future renumbering is then a single record change. | |

## Out of scope

- HA pfSense itself (separate, much bigger initiative)
- Multi-DC failover
- External etcd cluster (we're sticking with kubeadm-managed stacked etcd)
- Rebuilding cluster from scratch — we'll join into the existing one

## Risk register

| Risk | Mitigation |
|---|---|
| Phase 0 cert regen on existing master triggers a brief apiserver outage (~30s) | Already a known cluster behaviour during static-pod restart. Schedule during a low-activity window. Tigera/operators will crash-loop briefly but recover — same blast radius as today's k8s upgrade. **Once HA is up, future restarts won't have this surface at all.** |
| etcd quorum split-brain during member join | kubeadm join is atomic; if it fails, the new member doesn't join the quorum. Existing etcd stays healthy. |
| LB misconfiguration → all kubectl breaks | Smoke-test from each master directly (bypass LB) before flipping clients. Keep a kubeconfig pointing at `10.0.20.100:6443` as fallback. |
| Existing kubeconfigs (Woodpecker pipelines, agents, dev VM, in-cluster RBAC default) need updating | Single Terraform apply touches `stacks/rbac/modules/rbac/apiserver-oidc.tf` (default), `.woodpecker/*.yml` (committed kubeconfigs). Worker `kubelet.conf` files patched in Phase 4 via ssh loop. |
| New masters get scheduled workload pods unintentionally | Verify `node-role.kubernetes.io/control-plane:NoSchedule` taint is applied at join time (default with `--control-plane`). |
| Cert rotation propagation | kubeadm join uses the `--certificate-key` from `kubeadm init phase upload-certs` to fetch existing CA materials. Single short-lived secret in `kube-system/kubeadm-certs` (**2h TTL** — Phases 2 + 3 must complete within the window, or re-upload between them). |
| 32GB per master × 3 = 96GB RAM used for control plane alone | PVE host has 272GB total, 176GB allocated to cluster pre-HA. Post-HA: 240GB allocated, 32GB headroom. Sufficient. |
| Pre-existing kubeadm-config does NOT have `controlPlaneEndpoint` set | Phase 0 patches it. Verify: `kubectl -n kube-system get cm kubeadm-config -o yaml \| grep controlPlaneEndpoint` (absent → `10.0.20.99:6443` post-Phase 0). |
| Existing master cert SANs are `[k8s-master, 10.96.0.1, 10.0.20.100]` only — missing VIP | Phase 0 regens with `--apiserver-cert-extra-sans 10.0.20.99` after patching kubeadm-config. |

## Verification

After all 3 masters joined + LB up:

```bash
# All 3 masters listed
kubectl get nodes -l node-role.kubernetes.io/control-plane=

# etcd quorum healthy
kubectl -n kube-system exec etcd-k8s-master -- etcdctl \
    --endpoints=https://10.0.20.100:2379,https://10.0.20.110:2379,https://10.0.20.111:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
   
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    endpoint health --cluster

# Kubeconfig points at VIP
kubectl --kubeconfig ~/.kube/config config view --minify -o jsonpath='{.clusters[0].cluster.server}'
# Expect: https://10.0.20.99:6443

# Worker kubelet.conf points at VIP
for n in k8s-node{1,2,3,4}; do
  ssh wizard@$n.viktorbarzin.lan "sudo grep -E '^\s+server:' /etc/kubernetes/kubelet.conf"
done
# Expect: server: https://10.0.20.99:6443 on every node

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
- **~5-7 hours of operator time end-to-end** (cloud-init template bump + Phase 0 retrofit + LB + Phase 1.5 rbac refactor + 2× kubeadm join + Phase 4 cutover + Phase 4.5 etcd-backup fix + Phase 5 kured-gate + Phase 6 validation + Phase 7 chain extension). Phases 0–6 can land in one session; Phase 7 can be deferred a few days if needed.

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
