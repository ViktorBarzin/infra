# TopoLVM Migration Evaluation

**Date**: 2026-06-01
**Status**: ❌ NOT ADOPTED — superseded 2026-06-05.
**Decision**: **Rejected in favour of option ① (harden proxmox-csi + NFS)** — TopoLVM pins PVCs to a node, which loses the cross-node pod mobility Viktor requires (a node going down must let pods reschedule elsewhere), and Option C's hardware spend was declined. Longhorn was also rejected (replication is 2× write-amplification on the single shared sdc HDD, with no DR benefit on a single host). See `2026-06-05-block-storage-harden-nfs-design.md` for the chosen path and full rationale. This doc is retained for its analysis — the LUN-cap mechanics, the three disk-layout options, and the effort estimate remain accurate reference if a second physical host is ever added (which would revive the Longhorn/replication option).

## Problem statement

The cluster's block storage hits a **hardcoded 29-PVC-per-VM ceiling** in `sergelogvinov/proxmox-csi-plugin` (`pkg/csi/utils.go:394`, `for lun = 1; lun < 30; lun++`). The plugin scans Proxmox SCSI indices `scsi1..scsi29`; when all are taken, `ControllerPublishVolume` returns `Internal desc = no free lun found`. We hit this on 2026-05-26 with 4 stuck PVCs on k8s-node1 and responded by scaling from 4 → 6 worker VMs.

Path 1 (patch the plugin to `lun < 31`) buys +1 slot per VM. Path 2 (NFS-migrate non-DB workloads) buys 20-30 PVCs of headroom. Both are tactical. This doc evaluates **Path 3 — replace the CSI driver with TopoLVM**, which removes the cap permanently by changing the storage architecture from "PVE-host LVM-thin + SCSI hotplug" to "per-VM LVM-thin + local provisioning".

## What TopoLVM is

CSI driver from cybozu-go. Each K8s node runs an `lvmd` daemon managing one or more LVM volume groups. The CSI controller creates `LogicalVolume` CRDs; `topolvm-node` on the target node reconciles them by asking `lvmd` to `lvcreate` an LV in the chosen VG. The LV is mounted directly on the node (no virtio-scsi hotplug). PVCs are LV slices, not separate SCSI devices — there is no per-VM cap beyond kernel LV count limits (effectively thousands).

Mature project, used in production by Cybozu and others. Supports:
- Thin provisioning (`type: thin` device class with overprovision ratio)
- Multiple device classes per node (e.g., one for SSD, one for HDD)
- CSI VolumeSnapshot CRDs (thin-provisioned volumes only; restore pinned to source node)
- Online volume expansion (ext4, xfs, btrfs)
- Striping and RAID via `lvcreate-options`

## The big architectural trade-off — read this first

| Aspect | proxmox-csi (today) | TopoLVM |
|---|---|---|
| Storage location | PVE-host thin pool (sdc) | Per-VM thin pool on a dedicated disk |
| Per-VM PVC cap | **29** (plugin source) | None (kernel LV limits, thousands) |
| **PVC mobility** | **Migrates between VMs** — CSI re-attaches LV to wherever the pod schedules | **Pinned to one node** via `topology.topolvm.cybozu.com/node` label |
| Failure recovery | Pod reschedules to another VM, PVC follows | Pod can only restart on the same node; if the node dies, data is on the dead node |
| IO contention | All VMs share sdc thin pool | Each VM's pool is on its own disk (which may still share underlying physical media) |
| Snapshot mechanism | PVE-host `lvm-pvc-snapshot` script (custom) | CSI VolumeSnapshot CRDs (standard) |
| Encryption | LUKS via Proxmox CSI `extraParameters` + ESO-synced secret | LUKS via `csi.storage.k8s.io/{node-stage,node-expand}-secret` — same pattern, different secret target |
| Backup pipeline | sda → Synology via `daily-backup` script that mounts LVM snapshots on PVE | Same idea but snapshots live inside K8s VMs; backup script would need to run on each VM (or use CSI snapshot → object store) |
| Operational model | "Storage is a shared pool, VMs are cattle" | "Storage is per-node, like local-path with LVM features" |

**Data mobility is the most important difference.** Today, when k8s-node1 is drained for maintenance, all its PVC pods reschedule to other nodes and the proxmox-csi controller detaches/re-attaches the LVs accordingly. With TopoLVM, draining a node means **the PVC data is still on that node's local disk** — pods cannot start elsewhere until either (a) the data is migrated, or (b) the node returns.

For Viktor's setup specifically:
- **Pro**: the underlying PVE host is a single point of failure anyway (192.168.1.127). If the host dies, all VMs and all storage die together. The "mobility" of proxmox-csi is partially illusory at the homelab scale — the data isn't actually mobile across physical machines.
- **Con**: VM-level failures (kernel panic, OOM, manual qm shutdown for maintenance) DO happen routinely. Today, the pod just reschedules; with TopoLVM, you wait for the VM to recover or you accept downtime.
- **Mitigation**: For services that already have replication built in (CNPG Postgres cluster has 3 replicas, Redis-v2 has 3, Vault has 3-node Raft), the data-locality penalty is minimal — one replica's local LV being unavailable triggers a re-replication elsewhere. The PAIN is concentrated in single-replica stateful services: MySQL standalone, Nextcloud, Vaultwarden, mailserver, claude-memory, all the SQLite-backed services.

## Disk layout — three options

TopoLVM needs a dedicated LVM VG per node. Three ways to provision it:

### Option A — Carve from sdc (HDD), one VG per VM

Add a second virtual disk to each K8s VM, sized for its expected PVC load. The disk lives on the existing sdc thin pool. Format as LVM PV → its own VG → TopoLVM thin pool.

- **Sizing**: rough math from session-1 audit: 1.2 TB total LV allocation across 76 PVCs. Add 30% headroom = 1.6 TB. Distribute by current node placement:
  - node1: Prometheus (433G) + others ≈ 600-700 GiB → **768 GiB disk**
  - node2: Loki (50G) + smaller DBs ≈ 200 GiB → **256 GiB disk**
  - node3: MySQL standalone + Immich PG + several DBs ≈ 200 GiB → **256 GiB disk**
  - node4: smaller → **256 GiB disk**
  - node5: smaller → **256 GiB disk**
  - node6: Nextcloud + Vaultwarden + mailserver + small DBs ≈ 200 GiB → **256 GiB disk**
  - **Total: ~2 TiB** carved from sdc thin pool (currently 66% used, 3.5 TiB free)
- **Pro**: simplest physical change, no hardware needed, just `qm set --scsiN local-lvm:NNN`
- **Con**: IO contention on sdc unchanged. The 6 thin pools all sit on the same HDD physical layer. Storms hit harder because there's no inter-pool isolation at the LVM level.

### Option B — Move hot workloads to sdb (SSD), keep cold on sdc

Use a hybrid layout:
- Per-VM SSD disk (sdb, 931 GB total, ~675 GB free) for hot DBs
- Per-VM HDD disk (sdc) for cold/bulk

TopoLVM supports multiple device classes per node — each VM would have an `ssd-thin` and `hdd-thin` class.

- **Pro**: separates hot/cold IO; SSD-backed DBs are dramatically faster; partial IO-contention relief on sdc
- **Con**: 675 GB SSD has to host DBs across 6 VMs (~112 GiB each, tight). Need to identify which PVCs are hot. The encrypted PVCs (45 currently) are mostly DBs and would be the SSD candidates.

### Option C — Add a second physical disk for storage

Add a real SSD (e.g., a 2 TB NVMe) to the PVE host. Carve per-VM disks from it for TopoLVM. Keep sdc for VM root + nfs-data only.

- **Pro**: cleanest physical isolation. Solves both LUN cap AND IO contention (the underlying beads `code-oflt` task).
- **Con**: hardware investment. ~£200 for a 2 TB NVMe. Requires PVE host downtime to install. Existing PVE has 2 SATA ports used (sda + sdb) + M.2 slot (might be in use, need to check). LVM/thin pool setup is straightforward.

## Migration approach

Same pattern as the 2026-05-26 Wave 1 NFS migration, multiplied across more PVCs:

1. **Install TopoLVM alongside proxmox-csi** — both run in parallel; new StorageClass `topolvm-provisioner` and `topolvm-provisioner-encrypted` created without touching existing PVCs
2. **Per-VM data disk provisioning** — `qm set <vmid> --scsi8 local-lvm:NNN`, add `vgcreate` + `lvcreate` per VM (one-time)
3. **lvmd config per node** — Helm values point to the right VG per node
4. **Pilot migration** — pick a small, low-criticality PVC (e.g., a single-replica config-only service). Run the same scale-to-0 → rsync helper → swap claim_name → apply pattern from Wave 1. Validate.
5. **Phased rollout** — migrate PVCs in batches by criticality:
   - Wave A: regenerable / cache (5-10 PVCs, low risk)
   - Wave B: app config PVCs with SQLite (15-20 PVCs, blip per service)
   - Wave C: medium DBs (Postgres, MySQL, Redis with replicas) (10-15 PVCs)
   - Wave D: critical singletons (Vaultwarden, Nextcloud, mailserver, MySQL standalone) (5-10 PVCs)
   - Wave E: huge ones (Prometheus, Loki, Forgejo) (3-5 PVCs)
6. **Rewrite backup pipeline** — current `daily-backup` mounts LVM snapshots on PVE host; new flow needs to either (a) run snapshot logic inside each K8s VM via DaemonSet, or (b) use CSI VolumeSnapshot CRDs + an external-snapshotter → restic/borg backend
7. **Deprecate proxmox-csi** — once all PVCs migrated, remove the Helm release and the `proxmox-lvm` / `proxmox-lvm-encrypted` StorageClasses
8. **Update docs** — `docs/architecture/storage.md`, `CLAUDE.md`, ingress factory references, several runbooks

## Effort estimate

| Phase | Time | Notes |
|-------|------|-------|
| Decision + Option A/B/C pick | 1 day | Includes any hardware ordering for Option C |
| TopoLVM install + lvmd config | 1 day | Helm chart, secrets, RBAC, test on one node first |
| Per-VM data disk provisioning | 0.5 day | Six VMs; coordinate with kubelet restart |
| Encrypted PVC LUKS plumbing | 1 day | Verify the ExternalSecret pattern works with TopoLVM's secret refs |
| Pilot migration (1 PVC) | 0.5 day | Includes rollback rehearsal |
| Waves A-D migrations (~45 PVCs) | 5-7 days | ~20 min per PVC like Wave 1, plus verification |
| Wave E (huge PVCs) | 2-3 days | Prometheus 433 GiB will take hours to rsync; needs careful staging |
| Backup pipeline rewrite | 2-3 days | Snapshot-driven backup is a different model; testing |
| Deprecation + cleanup | 1 day | Remove proxmox-csi, update SCs, update docs |
| Docs + runbook updates | 1 day | storage.md, scale runbook, CLAUDE.md, post-mortems for incidents during migration |

**Total: ~2.5-3 weeks of focused infra time.** Could stretch over a quarter if done alongside other work.

## Risks

| Risk | Likelihood | Mitigation |
|------|------------|------------|
| Data loss during PVC migration | Low | Rsync with `--checksum`, verify before deleting source, keep proxmox-csi running until each migration validates |
| Data-locality penalty during VM reboot | High | Reboot one VM at a time; multi-replica services handle it; single-replica = brief downtime (same as today for kured-driven reboots, but more frequent in TopoLVM model) |
| LUKS encryption plumbing different from current | Medium | Pilot encrypted PVC migration before committing |
| Backup pipeline regression | High | Keep old `daily-backup` running until new pipeline proven for ≥2 weeks |
| Snapshot semantics change (restore pinned to source node) | Medium | Document; not a blocker for normal use but matters for cross-VM restore scenarios |
| TopoLVM does not solve IO contention | Certain (unless Option C) | Beads `code-oflt` remains open as a separate task |
| Migration window for huge PVCs (Prometheus 433G) | Medium | Stage during low-traffic period; use rsync with checkpoint resumption |
| Surprise incompatibility (Kyverno policy, Authentik, etc.) | Low | Pilot catches most |
| Reverse migration if we change our mind | Medium | Always possible via the same rsync pattern, but tedious |

## Decision criteria

Pick TopoLVM (any option) if:
- We hit the LUN cap repeatedly (≥2 incidents in 6 months)
- We want to fix IO contention at the same time (then Option C only)
- We're comfortable with single-node data locality

Stay on proxmox-csi if:
- The Path 1 + 2 combo gives us enough headroom for the foreseeable future
- We value data mobility (any-pod-can-run-anywhere) over architectural cleanliness
- The migration cost (3 weeks) outweighs the LUN-cap risk over the next year

## Recommended next steps if pursuing

1. **Run a small pilot first** — install TopoLVM on one node (k8s-node5 or node6 since they're newest and have less critical workloads), provision a 50 GB data disk, create a test PVC, migrate one tiny non-critical PVC, verify the operational pattern works end-to-end before committing to full migration
2. **Pick Option A or C** — Option B is too SSD-constrained for the encrypted PVC volume we have
3. **Order hardware if Option C** — NVMe + a hot-swap caddy or M.2 adapter; verify PVE host has the slot
4. **Schedule a 3-week window** — partition the migration waves around other infra commitments; flag in beads as a P1

## Related

- `docs/architecture/storage.md` — current storage architecture
- `docs/runbooks/scale-k8s-cluster.md` — current scaling playbook (Path 1+2 alternative)
- `docs/post-mortems/2026-05-25-immich-anca-elements-io-storm.md` — IO contention is the related-but-separate concern
- Beads `code-oflt` — IO isolation long-term fix (Option C would close this)
- Remote memory id=2788 — proxmox-csi-plugin LUN cap explanation
