# Volume-aware scheduling

Status: **superseded, not built** (2026-11-09). Viktor rejected both versions as
too complex and asked for a maintained solution. No maintained project scores or
rebalances by volume count, and preemption cannot free a volume slot (kube-scheduler
v1.35 `nodevolumelimits/csi.go:308-330` counts live VolumeAttachments). The chosen
path is the scheduler's own per-node limit set to 20, cluster-headroom alerts, and
fewer block volumes (`docs/research/2026-11-09-block-volume-db-consolidation.md`).
This file records the two designs and the challenger findings so they are not
rebuilt. v1 (volumes as an extended resource plus a descheduler profile) was
rejected after two challenger reviews; see "Rejected: v1" below.

## Problem

proxmox-csi hot-plugs each block PVC into the node VM. The scheduler enforces
`CSINode.allocatable.count` (28, from the node label
`csi.proxmox.sinextra.dev/max-volume-attachments`) as a filter only. It does not
score by volume count, and nothing moves pods back after a node returns. On
2026-11-09 k8s-node4 held 23-27 of 28 while node2 held 1-6, after kured reboot
waves (kured: 02:00-06:00 Europe/London, every day, concurrency 1). Hotplug
failures have happened at 20-23 disks per VM (`docs/architecture/storage.md`),
so 28 is above the safe zone.

Three resources constrain placement together: memory requests, GPU shares
(node1 only, 100 time-sliced shares, 8 used) and block-volume slots. Skew in one
fragments the others.

| resource | used | total | one node down |
|---|---|---|---|
| block volumes, cap 20 | 60 attached | 100 | 80, 75% used |
| memory requests | 130.5 GiB | ~176 GiB | lose node1 (48 GiB): 102%; lose a 32 GiB node: 91% |
| GPU shares | 8 | 100 | single GPU node |

Storage alternatives were ruled out in
`docs/research/2026-11-09-block-storage-without-slot-cap.md`; Viktor chose to keep
proxmox-csi. A block-to-NFS scan found only 4-8 volumes that could move safely.

## Goals

1. No node VM carries more block volumes than the safe cap.
2. Every placement weighs volume count together with memory and GPU, so skew
   after a node loss corrects itself through normal churn.
3. No extra hotplug events beyond today's churn.
4. Alerts fire on headroom for one node down, for volumes and memory.
5. No forked or long-lived custom code. Terraform-managed.

## Design

### 1. Rebalance node4, then lower the cap to 20

All 7 data-mounting broker-sync CronJobs are pinned to k8s-node4 on purpose
(memory #7019: one attach that stays, instead of a nightly hotplug). With node4
above 20, a cap of 20 would refuse their nightly attach. Order:

1. Daytime, outside kured's 02:00-06:00 window: move non-database volume pods off
   node4 until it holds 18 or fewer, by deleting the pod while node4 is
   cordoned. broker-sync stays pinned and counts as one of node4's slots.
2. Set `max-volume-attachments=20` in
   `stacks/proxmox-csi/modules/proxmox-csi/main.tf:229` and confirm
   `CSINode.allocatable.count` reads 20 on every worker.

### 2. Spread volume pods at placement

A Kyverno ClusterPolicy (stacks/kyverno), autogen off so Deployment templates are
not mutated and Terraform sees no drift:

- **Pod CREATE**, for pods owned by a ReplicaSet or StatefulSet with at least one
  PVC whose StorageClass name starts with `proxmox-lvm`: add the label
  `viktorbarzin.me/block-volume: "true"` and a preferred pod anti-affinity term
  with `namespaceSelector: {}`, `labelSelector` on that label, `topologyKey:
  kubernetes.io/hostname`. Job and CronJob pods are skipped: they share their
  app's RWO PVC and must co-locate with it.
- **Mutate-existing** rule adds the same label to running pods. Labels are
  mutable, so existing pods count at once with no restarts.

Why anti-affinity and not topology spread: `PodTopologySpread` counts only pods
in the incoming pod's namespace
(`pkg/scheduler/framework/plugins/podtopologyspread/scoring.go:186,218` at
v1.35.0), and almost every app has its own namespace. `InterPodAffinity` scoring
honours `namespaceSelector`
(`pkg/scheduler/framework/plugins/interpodaffinity/scoring.go:96-119`).

Effect: the default scheduler scores every placement on memory (LeastAllocated),
taints (node1 PreferNoSchedule) and the count of volume pods per node, with the
CSINode cap of 20 and the GPU request as hard filters. When kured drains a node,
its volume pods prefer the node with the fewest. The node that comes back empty
is preferred by the pods of the next node drained. Skew is bounded by the cap and
shrinks with each churn event. No evictions are added.

Limits: it counts pods, not volumes (vault pods carry 2). failurePolicy Ignore:
a pod created while Kyverno is down lacks the term and is placed by memory only;
the cap still holds.

### 3. Descheduler: no change

No descheduler plugin evicts on preferred anti-affinity, and every extra eviction
of a volume pod is a hotplug. `balance-by-requests` keeps `ignorePvcPods: true`.

### 4. Alerts

Replace `ProxmoxCSILunUsageHigh`, `...Critical`, `...CapReached` with:

- `BlockVolumeHeadroomLow` (warning): attached proxmox-csi volumes > 80% of
  (workers - 1) x 20 = 64.
- `NodeBlockVolumesOverCap` (warning): a node above 20 attached (ghosts, or pods
  placed before the cap).
- `ClusterMemoryRequestsN1` (warning): total memory requests exceed allocatable
  minus the largest node's allocatable. Fires today at 102%.

### 5. Docs

`docs/architecture/storage.md` (cap, spreading, alerts), `docs/agents/new-app.md`
(data in shared Postgres, NFS for bulk files, block only for software that locks
files), the healthcheck #47 comment, and this plan's status.

## Costs and risks

- One more Kyverno mutate policy in the pod admission path, with one PVC lookup
  per PVC volume.
- About 8 pod moves off node4, once, daytime.
- node1 (fewest volume pods) may attract non-GPU volume pods and their memory.
  The PreferNoSchedule taint pushes the other way; watch `ClusterMemoryRequestsN1`.
- Memory, not volumes, is the tighter one-node-down limit today.

## Rejected: v1

Volumes as an extended resource `viktorbarzin.me/block-volumes` with a descheduler
`LowNodeUtilization` profile. Challenger findings, verified:

- **Fatal:** kubelet zeroes every extended resource when it starts without a
  device-manager checkpoint (`pkg/kubelet/kubelet_node_status.go:190-204`), which
  is every start on node2-5. Volume pods would be refused after each reboot.
- **Fatal:** the Kyverno ConfigMap `resourceFilters` excludes `[Node,*,*]` and
  `[Node/?*,*,*]`, so Kyverno cannot maintain node status.
- **Serious:** a per-pod request double-counts PVCs shared with CronJobs.
- **Serious:** `LowNodeUtilization` evicts but does not choose a destination; pods
  could land back on the same node, a hotplug for nothing.
- **Serious:** a nightly window overlaps kured and nfs-mirror, the conditions of
  the 2026-11-02 poisoned-slot incident.

A VolumeAttachment-reading rebalancer CronJob (about 100 lines) was also
considered; it is custom code and adds hotplugs.

## Open questions

1. Weight of the anti-affinity term against LeastAllocated memory: start at 50,
   check placements after the first kured wave.
2. Whether `CSINode.allocatable.count` updates without restarting the
   proxmox-csi node DaemonSet.
