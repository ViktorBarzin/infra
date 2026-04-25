# NFS-Hostile Workload Migration — Design

**Date**: 2026-04-25
**Author**: Viktor (with Claude)
**Status**: Phase 1 done, Phase 2 in progress
**Beads**: code-gy7h (Vault), code-ahr7 (Immich PG)

## Problem

The 2026-04-22 Vault Raft leader deadlock (post-mortem
`2026-04-22-vault-raft-leader-deadlock.md`) traced to NFS client
writeback stalls poisoning kernel state. Recovery took 2h43m and
required hard-resetting 3 of 4 cluster VMs. Two workload classes on
NFS are NFS-hostile per the criteria in
`infra/.claude/CLAUDE.md` ("Critical services MUST NOT use NFS"):

1. **Postgres with WAL fsync per commit** — Immich primary
2. **Vault Raft consensus log** — fsync per append-entry, 3 replicas

Everything else on NFS (47 PVCs, ~455 GiB) is correctly placed:
RWX media libraries, append-only backups, ML caches.

## Decision

Migrate exactly those two workload classes to
`proxmox-lvm-encrypted` (LUKS2 LVM-thin via Proxmox CSI). No iSCSI,
no RWX media migration, no backup-target migration.

## Rationale

- Block storage decouples PG / Raft fsync from NFS client kernel
  state. Failure mode that triggered the post-mortem cannot recur for
  these workloads.
- `proxmox-lvm-encrypted` is the documented default for sensitive data
  (`infra/.claude/CLAUDE.md` storage decision rule). It already backs
  ~28 PVCs across the cluster — pattern is proven.
- Existing nightly `lvm-pvc-snapshot` PVE host script (03:00, 7-day
  retention) auto-picks-up new PVCs via thin snapshots — no extra
  backup wiring needed for the live data side.
- LUKS2 satisfies "encrypted at rest for sensitive data" requirement.

## Out of scope

- iSCSI evaluation (already retired 2026-04-13).
- RWX media (Immich library, music, ebooks) — correct placement.
- Backup target PVCs (`*-backup` on NFS) — append-only, NFS-tolerant.
- Prometheus 200 GiB — already on `proxmox-lvm`.

## Pattern per workload

### Immich PG (single replica, Deployment, Recreate strategy)

- Add new RWO PVC on `proxmox-lvm-encrypted`.
- Quiesce app pods (server + ML + frame).
- `pg_dumpall` from running NFS pod → local file.
- Swap deployment `claim_name` → encrypted PVC.
- PG bootstraps fresh on empty PVC; restore dump.
- REINDEX vector indexes (`clip_index`, `face_index`).
- Backup CronJob keeps writing to NFS module (correct: append-only).

### Vault Raft (3 replicas, StatefulSet, helm-managed)

- Change `dataStorage.storageClass` and `auditStorage.storageClass`
  from `nfs-proxmox` → `proxmox-lvm-encrypted`.
- StatefulSet `volumeClaimTemplates` is immutable → use
  `kubectl delete sts vault --cascade=orphan` then re-apply (memory
  pattern for VCT swaps).
- Per-pod rolling: delete pod + PVCs, controller recreates with new
  template. Auto-unseal sidecar handles unseal; raft `retry_join`
  rejoins cluster.
- 24h validation window between pods. Migrate non-leader pods first;
  step-down current leader before migrating it last.
- Backup target (`vault-backup-host` on NFS) stays on NFS.

## Risks and rollbacks

### Immich PG

- pg_dumpall captures schema + data, not file-level state. Vector
  index versions matter (vchord 0.3.0 unchanged; vector 0.8.0 →
  0.8.1 is a minor automatic bump on `CREATE EXTENSION` — confirmed
  benign). Rollback: revert `claim_name`, scale apps; old NFS PVC
  retained for 7 days post-migration.

### Vault Raft

- Cluster keeps quorum from 2 standby replicas while one pod is
  swapped. Migrating the leader last avoids quorum churn.
- Recovery anchor: pre-migration `vault operator raft snapshot save`
  + nightly `vault-raft-backup` CronJob. RTO < 1h via snapshot
  restore.

## Init container chicken-and-egg (Immich PG, discovered during execution)

The pre-existing `write-pg-override-conf` init container on the
Immich PG deployment writes `postgresql.override.conf` directly to
`PGDATA`. On a populated NFS PVC this was a no-op (init was already
run). On the fresh encrypted PVC, the file made `initdb` refuse the
non-empty directory and the pod CrashLoopBackOff'd.

Resolution: gate the init container on `PG_VERSION` presence — first
boot skips the override write, PG `initdb`s cleanly; force a pod
restart and the second boot writes the override and PG loads
`vchord` / `vectors` / `pg_prewarm` before the dump restore. Change
is permanent and idempotent (correct on both fresh and initialised
PVCs). One restart pre-migration only.

## Verification

End-to-end DONE when:

- `kubectl get pvc -A | grep nfs-proxmox` returns only the
  `vault-backup-host` PVC (or zero, if backup PVC moves elsewhere).
- `vault operator raft list-peers` shows 3 voters on
  `proxmox-lvm-encrypted`, leader elected.
- Immich PG `\dx` matches pre-migration extensions (vector minor
  drift OK).
- `lvm-pvc-snapshot` captures new LVs in next 03:00 run.
- 7 consecutive days of clean backup CronJob runs and no new alerts.
