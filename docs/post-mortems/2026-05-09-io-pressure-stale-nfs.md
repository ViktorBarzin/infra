# Post-Mortem: IO Pressure Stalls from Stale NFS Client to Decommissioned TrueNAS

| Field | Value |
|-------|-------|
| **Date** | 2026-05-09 (issue first observable in journal at 2026-05-08 00:00:04) |
| **Duration** | Intermittent IO PSI stalls and kubectl TLS handshake timeouts during the session; PVE host loadavg ~15 sustained. No user-visible outage. |
| **Severity** | SEV3 (degraded host I/O, no service down) |
| **Affected Components** | PVE host (192.168.1.127), `node_exporter` (PID 1479, D-state), kernel NFS kthread `[10.0.10.15-manager]`, k8s-node3 (downstream IO PSI). |
| **Status** | Resolved structurally. Stale connection source removed; recurring trigger eliminated. Wedged kthread persists in kernel queue — clears on next PVE reboot. |

## Summary

The PVE host's NFS client was retaining a wedged connection to `10.0.10.15` — the IP of the TrueNAS VM that was operationally decommissioned 2026-04-13 (storage migrated to `192.168.1.127:/srv/nfs`). The connection was created by `/usr/local/bin/weekly-backup`, a legacy script left over from before the NFS migration that had never been removed. Its kernel kthread `[10.0.10.15-manager]` parked itself in `rpc_wait_bit_killable` and stayed there. Any process that touched `/proc/mountstats` — including `node_exporter` — got dragged into D-state alongside it, which in turn fed back into IO pressure metrics. cluster-health surfaced this as `k8s-node3 full avg10=23%` and PVE loadavg sustained at ~15.

## Impact

- **User-facing**: None directly. Intermittent kubectl TLS handshake timeouts during the session, attributable to the elevated PVE loadavg.
- **Blast radius**: Single PVE host. node_exporter (PID 1479) wedged in D-state with the kthread. k8s-node3 downstream IO PSI peaked at `full avg10=23%`.
- **Data loss**: None.
- **Observability gap**: No alert fired for "stale NFS connection to decommissioned host". The IO PSI watchdog caught the symptom, not the cause.

## Root Cause

`/usr/local/bin/weekly-backup` was an artifact of the pre-2026-04-13 backup pipeline (when TrueNAS at `10.0.10.15` was the NFS server). After the TrueNAS decommission and migration to host NFS at `192.168.1.127`, the script was never deleted. It executed at least once recently (manually, or via a cron entry that has since been pruned), opening an NFS RPC session to `10.0.10.15`. With no peer answering, the kernel's RPC retry timer parked the manager kthread in `rpc_wait_bit_killable`. The kthread holds a lock that any reader of `/proc/mountstats` must take — `node_exporter` reads that file every scrape interval, so its scrape goroutine wedged in D-state too.

## Resolution

1. `lvextend -L +1T /dev/pve/nfs-data` + `resize2fs` — `/srv/nfs` 2 TiB → 3 TiB (90% → 60% used). Unrelated to the IO issue but bundled because `/srv/nfs` was at 90% and the user picked "grow LV" over "diet Immich". Thinpool (sdc) had ~4.6 TiB free.
2. `rm /usr/local/bin/weekly-backup` — eliminates the trigger. Backup pipeline is now `daily-backup.service` + `offsite-sync-backup.service` + per-app CronJobs (mysql/postgres/vault/etc.); `weekly-backup` was fully redundant.
3. `systemctl restart node_exporter` — replaces the wedged process. New PID 183319 healthy, `:9100/metrics` responsive.
4. `mysql-standalone` memory bump 2 Gi → 4 Gi limit, 1.5 Gi → 3 Gi request (commit forthcoming). Coincident May 8 18:05 OOM, not caused by this incident — `innodb_buffer_pool_size=1Gi` plus connection buffers and InnoDB internals didn't fit in 2 Gi.

## Open / Out-of-Scope

- **Wedged kthread `[10.0.10.15-manager]` (PID 3796184)** persists in the kernel queue. The kernel will eventually reap it once the RPC retry timer gives up, or it clears at next PVE reboot. With the script gone, no new ops queue against it. **Plan**: if PVE host PSI does not fully clear within 24 h, fold a PVE reboot into the next maintenance window. Not done in this change.
- **Transient OOMs unrelated to this incident**:
  - `mysql-standalone-0` May 8 18:05 (anon-rss 2 GB at 2 Gi limit) — addressed by the limit bump above.
  - postgres helpers May 9 12:37 — anon-rss <8 MB, pods no longer exist, no recurrence. No action.
  - python pod May 9 13:36 (anon-rss 518 MB on k8s-node2) — pod no longer exists, no recurrence. No action.
- **Pre-existing TF drift**: `null_resource.pg_job_hunter_db` in `stacks/dbaas/modules/dbaas/main.tf` execs against `pg-cluster-1`, but the current CNPG primary is `pg-cluster-2`. Unrelated to this incident; surfaced during the targeted MySQL apply. Fix is a separate ticket — should resolve the primary dynamically (e.g., via the `cnpg.io/instanceRole=primary` selector) instead of hardcoding pod ordinal.

## Action Items

- [x] Delete `/usr/local/bin/weekly-backup` on PVE host.
- [x] Restart `node_exporter.service` on PVE host.
- [x] Grow `pve/nfs-data` LV to 3 TiB; online `resize2fs`.
- [x] Bump `mysql-standalone` memory request/limit to 3 Gi / 4 Gi.
- [x] Update `docs/architecture/storage.md` to record the new LV size.
- [ ] Reboot PVE host at next maintenance window if `[10.0.10.15-manager]` kthread does not clear within 24 h.
- [ ] (Separate ticket) Fix `null_resource.pg_*_db` resources to target the actual CNPG primary instead of hardcoding `pg-cluster-1`.

## Related

- TrueNAS decommission: memory `id=674` (2026-04-13).
- Prior LV grow on `pve/nfs-data` (2 TiB out-of-band): memory `id=691` (2026-04-12).
- Architecture: `docs/architecture/storage.md`, `docs/architecture/backup-dr.md`.
