# Block-Storage Scaling — Harden proxmox-csi + NFS (Decision + Design)

**Date**: 2026-06-05
**Status**: Decided — supersedes the recommendation in `2026-06-01-topolvm-evaluation.md`
**Decision owner**: Viktor

## TL;DR

We keep the **proxmox-csi** block-storage model (which already gives cross-node
PVC mobility) and **harden** it, rather than re-architecting to TopoLVM or
Longhorn. The 29-PVC/node cap is made *unreachable* (not removed) by shrinking
the block footprint via NFS migration of non-DB workloads; the ghost-disk
doom-loop is *prevented* (not just detected); and node placement is rebalanced.
**£0, no new hardware, mobility preserved.**

## Why this, not TopoLVM / Longhorn

Hard constraints set by Viktor (2026-06-05): **(a)** must keep the ability to
move pods across VM nodes if one goes down (mobility), **(b)** no new hardware,
**(c)** sdc IO contention is acceptable / not worth spending on.

Key architectural insight that drove the decision:

- **Mobility and the LUN cap are two sides of the same mechanism.** proxmox-csi
  gives mobility *because* it hot-plugs each PVC as a Proxmox virtio-scsi disk
  that re-attaches wherever the pod lands — and that hot-plug is exactly what
  imposes the `lun < 30` cap and spawns the query-pci ghost-disk loop.
- **TopoLVM** removes the cap by killing the hot-plug — which is *why* it pins a
  PVC to one node. Rejected: violates constraint (a).
- **Longhorn** keeps mobility via replication, but mobility-via-replication
  costs **≥2× writes** (1 replica = no failover). On a single PVE host both
  replicas land on the same sdc HDD — you pay double the write IO for redundancy
  that dies with the host anyway (host = SPOF). Longhorn's own docs say "use a
  dedicated disk, not the root disk." Rejected: wasteful on a single host;
  reconsider only if a 2nd physical host is added.
- proxmox-csi already provides mobility at **1× write** (centralized LV
  re-attaches) — strictly more IO-efficient than replication on one host. The
  cap and ghost-loop are *warts on a good model*, not reasons to replace it.

| Option | 29-cap | Ghost loop | Mobility | sdc IO | Hardware | Verdict |
|---|---|---|---|---|---|---|
| **① Harden proxmox-csi + NFS** | managed (far off) | prevented | ✅ kept (1×) | same/better | £0 | **CHOSEN** |
| TopoLVM (A/C) | removed | eliminated | ❌ pinned | A: same / C: better | £0 / £200 | rejected — loses mobility |
| Longhorn | removed | eliminated | ✅ (2×) | worse | £0 | rejected — replication wasted on 1 host |

## Live state at decision time (2026-06-05)

- 6 workers (VMID 201–206), proxmox-csi `CSINode.allocatable.count = 28`/node →
  **168 slots**; **69 used (41%)**; **0 PVCs Pending**.
- **Imbalance is the live risk, not aggregate capacity**: node6 **21/28** (hot),
  node5 **3/28**. node1=9, node2/3/4=12.
- **Ghost-disk drift = 0** (the 2026-06-04 cleanup held; `qm config` scsi counts
  match tracked VolumeAttachments). Prevention still open (beads `code-dfjn`).
  Retained `unusedN` LVs: node1=6, node2=9, node3=6 (harmless to the cap).
- Block PVCs: **74** (44 encrypted + 30 plain). NFS: 64. local-path: 9.
- PVE host RAM **222/267 GiB used, swap in use** → adding more worker VMs is
  memory-bound (the May 4→6 escape hatch is mostly spent).
- sdc thin pool `data`: 69.67% data / 15.89% meta. `nfs-data` LV 74% of 4 TiB.
  VG `pve` raw free <16 GiB; VG `ssd` free 475 GiB.

## NFS-migration candidates (embedded-DB preflight is mandatory)

Rule: embedded transactional stores (SQLite/LevelDB/RocksDB/H2/LMDB/ClickHouse)
corrupt on NFS; sensitive `-encrypted` PVCs lose LUKS-at-rest on NFS. Only
non-DB, non-sensitive (or app-encrypted) workloads qualify.

**Verified NFS-safe (preflighted 2026-06-05, no embedded DB):**

| PVC | Node | SC | Evidence |
|---|---|---|---|
| `tandoor/tandoor-data-proxmox` | node6 | proxmox-lvm | `/opt/recipes/mediafiles` = media + bundled static; PG-backed |
| `speedtest/speedtest-config-proxmox` | node6 | proxmox-lvm | `/config` = logs (383 MB `laravel.log`) + config; MySQL-backed |
| `hackmd/hackmd-data-encrypted` | node6 | encrypted | `/…/public/uploads` = PNG uploads (4.5 MB); MySQL-backed |
| `changedetection/changedetection-data-proxmox` | node6 | proxmox-lvm | `/datastore` = JSON + brotli snapshots; no DB |
| `send/send-data-proxmox` | node2 | proxmox-lvm | `/uploads` = encrypted blobs; Redis metadata |

**Phase-1 candidates (preflight before migrating):** instagram-poster,
insta2spotify, novelapp, openclaw/openlobster, servarr/qbittorrent, postiz
(scaled-0), priority-pass-uploads*, tripit-personal-documents* (*app-encrypted /
sensitive — keep app-layer crypto, confirm before moving).

**Must stay on block** (embedded DB or fsync-critical): vaultwarden, ntfy,
uptime-kuma, navidrome, actualbudget×3, openclaw×2, servarr arr-apps, freshrss
(SQLite); stirling-pdf (H2); rybbit (ClickHouse); beads/dolt; all CNPG
pg-cluster, mysql-standalone, immich-pg, redis; prometheus, alertmanager, loki,
vault×3, technitium×3, mailserver, paperless, forgejo, matrix, n8n.

## Plan

### Phase 0 — Tactical relief (now): migrate the 5 verified-safe PVCs
Per service, following the proven 2026-05-26 Wave-1 pattern (reversible — source
block PVC kept until the NFS copy is verified):
1. `presence claim service:<svc>`.
2. Create NFS export dir on PVE host + add to git-managed
   `infra/scripts/pve-nfs-exports`; `exportfs -ra`.
3. Add `module "nfs_<svc>"` (`modules/kubernetes/nfs_volume`) to the stack;
   `scripts/tg apply` to create the static NFS PV/PVC.
4. Scale the workload to 0 (RWO → must release the block PVC).
5. rsync block→NFS with `--checksum` (exclude cruft: changedetection
   `test-direct`/`test-seq`/`lost+found`; speedtest can drop `log/`).
6. Swap the workload's `claim_name` to the NFS PVC; `tg apply`; scale up.
7. Verify app health + data intact.
8. Delete the old block PVC → frees the LUN slot; confirm with check #47.
9. Commit + push per service; wait for CI/Woodpecker.

Result: node6 **21 → 17**, node2 **12 → 11**.
hackmd note: confirm the LUKS→NFS downgrade is acceptable (low-sensitivity doc
images) or leave hackmd on encrypted block and accept 21→18.

### Phase 1 — Broader NFS sweep (this session if smooth, else tracked)
Preflight + migrate the Phase-1 candidates above. Goal: leave **only true DBs +
fsync-critical** services on block, so per-node block counts stay well under the
cap with years of runway.

### Phase 2 — Ghost-loop prevention (beads `code-dfjn`; design separately)
The structural half of "harden". Substantial — propose to design + plan on its
own rather than rush:
- Soft-cap block PVCs/node below the query-pci failure threshold (observed safe
  ≤24, fails ≥25) — alert + scheduler hint.
- Raise the proxmox-csi controller's QMP/query-pci timeout (and/or QEMU side).
- Auto-reconcile CronJob: detect drift (check #47 logic) → safe
  `qm set <vmid> --delete scsiN` (detach-only, retains LV).
- Rebalance residual node6 block PVCs → node5, one at a time, check #47 watching.

### Phase 3 — Docs
Update `storage.md` (Wave-2 NFS migration + the ① decision), `scale-k8s-cluster.md`,
`.claude/reference/service-catalog.md`; add a "Decided: ①" banner to
`2026-06-01-topolvm-evaluation.md` pointing here.

## Risks
- Data loss during migration → mitigated by rsync `--checksum` + keep source
  until verified + the workload is scaled-0 during copy.
- LUKS-at-rest dropped for `-encrypted` PVCs moved to NFS → only migrate
  low-sensitivity or app-encrypted ones; flag each.
- NFS soft-mount semantics → only non-DB workloads (preflighted); `nfsvers=4`,
  `soft,timeo=30,retrans=3` per the `nfs_volume` module defaults.
- Block rebalance (Phase 2) re-introduces detach/reattach ghost risk → one at a
  time with check #47.

## Related
- `2026-06-01-topolvm-evaluation.md` (superseded recommendation)
- `docs/architecture/storage.md` § "Per-VM SCSI-LUN cap"
- `docs/runbooks/scale-k8s-cluster.md`
- beads `code-dfjn` (ghost prevention), `code-oflt` (IO isolation — not pursued here)
