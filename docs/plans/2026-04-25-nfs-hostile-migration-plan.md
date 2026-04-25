# NFS-Hostile Workload Migration — Plan

**Date**: 2026-04-25
**Design**: `2026-04-25-nfs-hostile-migration-design.md`
**Beads**: code-gy7h (Vault, epic), code-ahr7 (Immich PG)

## Phase 1 — Immich PG (DONE 2026-04-25)

| Step | Done |
|---|---|
| Snapshot extensions + row counts to `/tmp/immich-pre-migration-*` | ✓ |
| Quiesce `immich-server` + `immich-machine-learning` + `immich-frame` | ✓ |
| `pg_dumpall` → `/tmp/immich-pre-migration-<ts>.sql` (1.9 GB) | ✓ |
| Add `kubernetes_persistent_volume_claim.immich_postgresql_encrypted` (10Gi, autoresize 20Gi cap) | ✓ |
| Swap `claim_name` at `infra/stacks/immich/main.tf` deployment | ✓ |
| Patch init container to gate on `PG_VERSION` (chicken-and-egg fix) | ✓ |
| Force pod restart so override.conf gets written | ✓ |
| Restore dump | ✓ |
| `REINDEX clip_index`, `REINDEX face_index` | ✓ |
| Scale apps back up | ✓ |
| Verify: `\dx`, row counts (~111k assets), HTTP 200 internal/external | ✓ |
| LV present on PVE host (`vm-9999-pvc-...`) | ✓ |

### Phase 1 follow-ups (not blocking)

- Old NFS PVC `immich-postgresql-data-host` retained 7 days for
  rollback. After 2026-05-02: remove `module.nfs_postgresql_host`
  from `infra/stacks/immich/main.tf` and the CronJob's reference.
- Backup CronJob (`postgresql-backup`) still writes to the NFS
  module. After cleanup, point it at a dedicated backup PVC or to
  the existing `immich-backups` NFS share.

## Phase 2 — Vault Raft (IN PROGRESS)

### Pre-flight (T-0)

- [ ] Verify all 3 vault pods sealed=false, raft healthy.
- [ ] Take fresh `vault operator raft snapshot save` (anchor).
- [ ] Optional: scale ESO to 0 to reduce mid-migration churn.
- [ ] Step-down leader if it's not vault-0 (current leader: vault-2 — needs step-down).
- [ ] Verify thin pool headroom on PVE.

### Step 0 — Helm values + StatefulSet swap

- [ ] Edit `infra/stacks/vault/main.tf`: change
      `dataStorage.storageClass` and `auditStorage.storageClass`
      from `nfs-proxmox` → `proxmox-lvm-encrypted`.
- [ ] `kubectl -n vault delete sts vault --cascade=orphan` (StatefulSet
      `volumeClaimTemplates` is immutable; orphan keeps pods+PVCs
      alive while we recreate the controller with the new template).
- [ ] `tg apply` → recreates StatefulSet with new VCT. Existing pods
      still on old NFS PVCs.

### Step 1 — Roll vault-2 (T+0)

- [ ] `kubectl -n vault delete pod vault-2 --grace-period=30`
- [ ] `kubectl -n vault delete pvc data-vault-2 audit-vault-2`
- [ ] STS controller recreates pod; new PVCs auto-provision on
      `proxmox-lvm-encrypted`.
- [ ] Wait Ready; auto-unseal sidecar unseals; `retry_join` rejoins
      raft cluster.
- [ ] Verify: `vault operator raft list-peers` shows 3 voters,
      vault-2 reachable.

### Step 2 — 24h soak

Wait 24h. Confirm no Raft alarms, no Vault errors, downstream
healthy. Rollback window for vault-2 closes here.

### Step 3 — Roll vault-1 (T+24h)

Same shape as Step 1.

### Step 4 — 24h soak

### Step 5 — Roll vault-0 (T+48h)

- [ ] If vault-0 is leader at this point, step-down first:
      `kubectl -n vault exec vault-0 -- vault operator step-down`.
- [ ] Then delete pod + PVCs as Step 1.

### Step 6 — Cleanup

- [ ] Re-enable ESO if disabled: `kubectl -n external-secrets scale deploy external-secrets --replicas=2`.
- [ ] Verify `kubectl get pvc -A | grep nfs-proxmox` returns zero
      live-data results (only backup-host should remain, if any).
- [ ] If no consumers: remove inline `kubernetes_storage_class.nfs_proxmox`
      from `infra/stacks/vault/main.tf` (lines 29-42).

### Verify (after each pod, then again at the end)

- [ ] All 3 PVC pairs on `proxmox-lvm-encrypted`.
- [ ] `vault operator raft autopilot state` healthy=true.
- [ ] External `https://vault.viktorbarzin.me/v1/sys/health` = 200.
- [ ] `vault-raft-backup` CronJob completes overnight (writes to NFS,
      stays NFS — correct).
- [ ] No Prometheus alerts (`VaultSealed`, `VaultLeaderless`).

## Phase 3 — Released-PV cleanup (FOLLOW-UP)

After Phase 1+2 land cleanly, ~30 PVs in `Released` hold dead LVs.
Reclaim by:

1. List Released PVs, confirm LV exists on PVE.
2. `kubectl delete pv <name>` (CSI removes underlying LV when PV is
   orphaned with `Retain` reclaim policy and no PVC reference).
3. If LV survives: manual `lvremove pve/vm-9999-pvc-<uuid>`.

## Rollback

| Phase | Trigger | Action |
|---|---|---|
| 1 | Immich UI broken / data loss | Revert `claim_name`; restore from `/tmp/immich-pre-migration-*.sql` to old NFS PVC |
| 2 (mid-rolling) | Single pod broken | Delete the encrypted PVC; recreate with NFS SC explicitly; cluster keeps quorum from 2 healthy pods |
| 2 (post-rolling, raft corrupt) | Cluster-wide failure | `vault operator raft snapshot restore <pre-migration.snap>` |
| Catastrophic | All Vault data lost | Restore from latest `/srv/nfs/vault-backup/` snapshot via CronJob output |
