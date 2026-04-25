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

### Pre-flight (T-0) — DONE 2026-04-25 15:50 UTC

- [x] Verify all 3 vault pods sealed=false, raft healthy.
- [x] Take fresh `vault operator raft snapshot save` (anchor saved at
      `/tmp/vault-pre-migration-20260425-155029.snap`, 1.5 MB).
- [ ] Optional: scale ESO to 0 — skipped (auto-unseal sidecar is
      independent; ESO refresh churn is non-disruptive for one swap).
- [x] Confirmed leader is **vault-2** → migrate vault-0 first
      (non-leader), vault-1 next, vault-2 last (with step-down).
      Plan originally assumed vault-0 was leader; same intent
      (non-leader first).
- [x] Thin pool headroom: 54.63% used, plenty for 6 × 2 GiB LVs.

### Step 0 — Helm values + StatefulSet swap — DONE 2026-04-25 16:08 UTC

- [x] Edit `infra/stacks/vault/main.tf`: change
      `dataStorage.storageClass` and `auditStorage.storageClass`
      from `nfs-proxmox` → `proxmox-lvm-encrypted`.
- [x] `kubectl -n vault delete sts vault --cascade=orphan` (StatefulSet
      `volumeClaimTemplates` is immutable; orphan keeps pods+PVCs
      alive while we recreate the controller with the new template).
- [x] `tg apply -target=helm_release.vault` → recreates STS with new
      VCT (full-stack `tg plan` blocks on unrelated for_each-with-
      apply-time-keys errors at lines 848/865/909/917; targeted
      apply on the helm release alone is the right scope here).
      Existing pods still on old NFS PVCs.

### Step 1 — Roll vault-0 first (non-leader) — DONE 2026-04-25 16:18 UTC

- [x] `kubectl -n vault delete pod vault-0 --grace-period=30`
- [x] `kubectl -n vault delete pvc data-vault-0 audit-vault-0`
- [x] STS controller recreated pod; new PVCs auto-provisioned on
      `proxmox-lvm-encrypted` (LVs `vm-9999-pvc-fb732fd7-...` data
      4.12%, `vm-9999-pvc-36451f42-...` audit 3.99%).
- [x] **Hit and fixed**: vault-0 CrashLoopBackOff'd with
      `permission denied` on `/vault/data/vault.db`. The helm chart's
      `statefulSet.securityContext.pod` block in main.tf only set
      `fsGroupChangePolicy`, replacing (not merging) the chart's
      defaults `fsGroup=1000, runAsGroup=1000, runAsUser=100,
      runAsNonRoot=true`. NFS exports made the missing fsGroup a
      no-op; ext4 LV needs it to chown the volume root for the
      vault user. Old vault-1/vault-2 pods were created before that
      block was added so they still had the chart-default
      securityContext from their original spec. Fix: provide all
      five fields explicitly in main.tf and re-apply. Same root
      cause will affect vault-1 and vault-2 swaps unless this stays
      in place.
- [x] Wait Ready; auto-unseal sidecar unsealed; `retry_join` rejoined
      raft cluster.
- [x] Verify: `vault operator raft list-peers` shows 3 voters,
      vault-0 follower, leader=vault-2. External HTTPS 200.

### Step 2 — 24h soak (IN PROGRESS, ends ~2026-04-26 16:18 UTC)

Wait 24h. Confirm no Raft alarms, no Vault errors, downstream
healthy. Rollback window for vault-0 closes here.

### Step 3 — Roll vault-1 (T+24h)

Same shape as Step 1. The securityContext fix is now in main.tf
so this should be straightforward.

### Step 4 — 24h soak

### Step 5 — Roll vault-2 (T+48h, leader)

- [ ] Step-down vault-2 first:
      `kubectl -n vault exec vault-2 -- vault operator step-down`.
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
