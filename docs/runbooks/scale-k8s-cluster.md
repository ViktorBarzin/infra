# Runbook: Scale K8s worker count (PVC capacity headroom)

Use when block-PVC pressure, memory pressure, or planned workload growth requires adding or removing K8s worker VMs. The cluster currently runs **6 workers (k8s-node1..6) + 1 control plane (k8s-master)**, sized to absorb the 2026-05-26 proxmox-csi LUN-cap incident with sustained headroom.

## Current shape

| Node | VMID | Memory | Disk | Special |
|------|------|--------|------|---------|
| k8s-master | 200 | 32 GiB | 64G | Control plane, no worker workloads |
| k8s-node1 | 201 | 48 GiB | 256G | GPU host (NVIDIA Tesla T4 passthrough), DNS primary |
| k8s-node2 | 202 | 32 GiB | 256G | |
| k8s-node3 | 203 | 32 GiB | 256G | |
| k8s-node4 | 204 | 32 GiB | 256G | |
| k8s-node5 | 205 | 32 GiB | 256G | Added 2026-05-26 (LUN-cap incident) |
| k8s-node6 | 206 | 32 GiB | 256G | Added 2026-05-26 (LUN-cap incident) |

Capacity envelope (6 workers): **174 block-PVC slots**, ~192 GiB memory, ~96 vCPU, GPU on node1 only. Pod cap is kubelet-default 110/node.

## Binding constraints — read these first

The cluster has 6 capacity dimensions. The one that bites first depends on workload shape; check each before adding/removing nodes.

1. **Per-VM block-PVC ceiling = 29** — hardcoded by `sergelogvinov/proxmox-csi-plugin` at `pkg/csi/utils.go:394` (`for lun = 1; lun < 30; lun++`). Symptom: pods stuck `ContainerCreating` with `FailedAttachVolume … no free lun found`. `CSINode.allocatable.count` advertises `28`/node. Switching `scsihw` to `virtio-scsi-single` does NOT raise this — it's a plugin constraint, not a Proxmox/QEMU one. See `docs/architecture/storage.md` § "Per-VM SCSI-LUN cap".

2. **Memory commitment** — node1 has historically run hot (was 117% of limits before the 2026-06 memory bump to 48 GiB). Treat memory as the next-binding constraint after PVC slots, especially since limits-vs-requests divergence isn't enforced by the scheduler.

3. **sdc IO contention** — every K8s VM disk + TrueNAS NFS LV live on the same Proxmox thin pool on sdc (10.7 TB RAID1 HDD). Three IO storms in 17 days (2026-05-09, 2026-05-16/17, 2026-05-25) — see `docs/post-mortems/2026-05-25-immich-anca-elements-io-storm.md`. Adding workers redistributes block PVCs but does NOT relieve underlying disk contention; that's beads `code-oflt`.

4. **GPU concentration** — Tesla T4 is passthrough-only on node1. Frigate ML / Immich ML / Whisper / Piper / llama-cpp all schedule there via `nvidia.com/gpu.present` label. Cannot be spread without provisioning a second GPU node.

5. **PVE host memory** — total PVE RAM 320 GiB. K8s VMs claim 240 GiB; TrueNAS / pfsense / Windows VMs claim ~80 GiB more. Adding a 32-GiB worker requires verifying PVE has the headroom (`free -h`).

6. **Per-stack Terraform state** — adding/removing nodes does NOT live in any single Terragrunt stack today. VMs are created via `scripts/provision-k8s-worker` (which calls `qm clone`). They are *not* managed declaratively in TF. Consequence: removal is a manual `kubectl delete node` + `qm stop` + `qm destroy`, not `tg destroy`.

## When to scale UP (add a worker)

Add a worker when **any** of these is true for ≥7 days:

| Trigger | Threshold | How to observe |
|---------|-----------|----------------|
| PVC slots per node | `max(per-node VA count) ≥ 25` (~86% of 29 cap) | `kubectl get volumeattachment -o json \| jq -r '.items[].spec.nodeName' \| sort \| uniq -c` |
| Cluster memory requests | `> 90%` | `kubectl describe nodes \| grep -A4 "Allocated resources"` or Goldilocks dashboard |
| Planned PVC additions | ≥3 net-new block PVCs in next sprint AND current max VA ≥ 22 | Project-tracker / beads |
| LUN-cap incident | Even one `no free lun found` event | Prometheus alert `ProxmoxCSILunsExhausted` (added 2026-05-31, commit `aded77d5`) |
| Sustained pod-eviction churn | Eviction count > 20/day for ≥3 days | `kubectl get events -A --field-selector reason=Evicted` |

### Playbook — add a worker

```bash
# 1. Choose VMID + IP (next free in 10.0.20.0/22 worker range, 10.0.20.105+ used)
NEXT_VMID=207
NEXT_IP=10.0.20.107
NAME=k8s-node7

# 2. Verify PVE memory headroom (need ≥34 GiB free for a 32-GiB VM with overhead)
ssh root@192.168.1.127 'free -h; pvesh get /nodes/pve/status --output-format=json | jq .memory'

# 3. Verify thin pool has space (need ≥256 GiB raw thin allocation, but thin so only growth matters)
ssh root@192.168.1.127 'lvs pve/data'

# 4. Clone + cloud-init + auto-join (idempotent — aborts if VMID or IP exists)
scp scripts/provision-k8s-worker root@192.168.1.127:/tmp/
ssh root@192.168.1.127 'bash /tmp/provision-k8s-worker '"$NAME $NEXT_VMID $NEXT_IP"

# 5. Wait for node to appear Ready (3-5 min for cloud-init + kubeadm join)
kubectl get nodes -w

# 6. Verify CSI registration (proxmox-csi + nfs-csi node pods)
kubectl get pods -A -o wide --field-selector spec.nodeName=$NAME | grep -E "csi|calico"

# 7. Confirm Goldilocks / Kyverno / Prometheus targets it (DaemonSets populate within ~2 min)
kubectl get ds -A -o wide | awk '{print $7,$8}' | head -20

# 8. Update this runbook's "Current shape" table
```

**Post-add validation:**
- `kubectl top node $NAME` reports stats (kubelet metrics OK)
- A test pod with a `proxmox-lvm` PVC schedules there and binds
- No new alerts firing in monitoring

## When to scale DOWN (drain a worker)

Scale down when **all** of these hold for ≥30 days:

| Condition | Threshold |
|-----------|-----------|
| Max-node PVC count | `≤ 20` (≈70% of cap) |
| Cluster memory requests | `< 70%` |
| Cluster memory limits | `< 95%` (no over-committed node) |
| No upcoming workload additions | Confirmed via beads / project tracker |

Scaling down is also reasonable as a deliberate trade-off (cost, IO reduction, consolidation) even if thresholds aren't met — but accept that the next scale-up cycle will incur the LUN-cap risk again.

### Playbook — drain + remove a worker

**Pick the lightest node first.** Survey before draining:

```bash
NODE=k8s-node5

# 1. Inventory what's there
kubectl get pods -A -o wide --field-selector spec.nodeName=$NODE \
  | awk 'NR>1 {print $1}' | sort | uniq -c   # pods per namespace

# 2. List drain blockers (local-path PVCs in use, GPU pods, single-replica services)
kubectl get pvc -A -o json | jq -r --arg n "$NODE" '.items[]
  | select(.spec.storageClassName == "local-path")
  | select(.status.phase == "Bound")
  | "\(.metadata.namespace)/\(.metadata.name)"'

# 3. Check presence board — is anyone mutating workloads on this node right now?
~/code/scripts/presence list
# If a `service:*` claim covers any pod on $NODE, DEFER until released.

# 4. Cordon (mark unschedulable, existing pods stay)
kubectl cordon $NODE

# 5. Watch memory pressure forecast on remaining nodes BEFORE evicting
kubectl top nodes  # baseline
# Expected addition: ~ (sum of pod memory requests on $NODE) / (N - 1) per other node

# 6. Drain (respects PDBs; --delete-emptydir-data needed for tmp volumes)
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data --timeout=15m

# Expected blips during drain (~30s-2min each for PVC reattach):
#   any singleton on $NODE (Deployment replicas=1 or StatefulSet with no peers)
# Multi-replica services with PDB just roll without downtime.

# 7. Verify everything rescheduled cleanly
kubectl get pods -A -o wide --field-selector spec.nodeName=$NODE
# Should show only DaemonSet pods + Completed jobs

# 8. Remove from cluster
kubectl delete node $NODE

# 9. Shut down + (optional) destroy the VM
VMID=205
ssh root@192.168.1.127 "qm shutdown $VMID --timeout 300; qm status $VMID"
# To fully destroy (frees thin-pool space):
# ssh root@192.168.1.127 "qm destroy $VMID --purge"

# 10. Verify post-drain shape
kubectl get volumeattachment -o json \
  | jq -r '.items[] | select(.spec.attacher == "csi.proxmox.sinextra.dev") | .spec.nodeName' \
  | sort | uniq -c

# 11. Update this runbook's "Current shape" table
```

**Cold-spare option:** instead of `qm destroy`, keep the VM stopped. The 256 GiB disk stays allocated on thin pool but the VM consumes no CPU/RAM. Re-add via `qm start <VMID>` + `kubeadm join` (the snippet still lives at `/var/lib/vz/snippets/k8s_cloud_init.yaml`).

## Special cases

### Critical singletons that blip during drain

These services are single-replica and incur ~30s-2min outages while their PVC reattaches to the new node:

- **Stateful databases**: `mysql-standalone-0`, `pg-cluster-*` members (CNPG handles failover gracefully)
- **Mail**: `mailserver`, `roundcubemail` (Dovecot maildir locking — defer if mid-incident)
- **Browser-trust services**: `nextcloud` (sessions reset), `vaultwarden` (active sessions blip)
- **Observability**: `prometheus-server` (scrape data gap), `claude-memory`
- **Self-hosted apps with SQLite**: hackmd, n8n, paperless-ngx, freshrss, navidrome, audiobookshelf

Coordinate the drain timing with users if any of these is on the node being drained. Single-pod Postgres/MySQL DBs are the most painful — schedule during low-traffic windows.

### GPU pods

GPU pods scheduled via `nvidia.com/gpu.present=true` node selector. They **cannot** drain off node1; if node1 itself needs maintenance, scale GPU workloads to 0 first or defer drain. See `docs/runbooks/k8s-node-auto-upgrades.md` for the kured-driven reboot path.

### Active sessions

Check `~/code/scripts/presence list` before any drain. If another session holds a claim on a service hosted on the target node, defer or coordinate.

### Force-clean stuck VolumeAttachments

If a drained node has lingering VolumeAttachment entries after `kubectl delete node`:

```bash
kubectl get volumeattachment -o json \
  | jq -r --arg n "$NODE" '.items[] | select(.spec.nodeName == $n) | .metadata.name' \
  | xargs -r kubectl patch volumeattachment -p '{"metadata":{"finalizers":null}}' --type=merge
kubectl get volumeattachment -o json \
  | jq -r --arg n "$NODE" '.items[] | select(.spec.nodeName == $n) | .metadata.name' \
  | xargs -r kubectl delete volumeattachment
```

## Related

- `docs/architecture/storage.md` § "Per-VM SCSI-LUN cap" — root-cause explanation of the PVC ceiling
- `docs/post-mortems/2026-05-25-immich-anca-elements-io-storm.md` — IO contention on sdc
- `docs/runbooks/k8s-node-auto-upgrades.md` — kured-driven rolling reboots (separate from scale)
- `docs/runbooks/restore-full-cluster.md` — disaster scenarios
- `scripts/provision-k8s-worker` — the actual cloning/join script
- Beads `code-oflt` — IO isolation (long-term fix for sdc contention)
- Remote memory id=2788 — `proxmox-csi-plugin hardcodes a per-VM SCSI-LUN ceiling`
