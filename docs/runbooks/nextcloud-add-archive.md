# Runbook: Add a new archive to Nextcloud / PVE NFS

Use this runbook when you need to surface a new directory under `/srv/nfs/` or `/srv/nfs-ssd/` to specific Nextcloud users as a dedicated External mount. Each archive gets its own NC mount; only the listed `applicableUsers` can see and access it.

## Steps

1. **Create the directory on PVE.**

   ```bash
   ssh root@192.168.1.127
   mkdir -p /srv/nfs/<archive-name>
   # Use /srv/nfs-ssd/<archive-name> for the SSD pool instead.
   ```

2. **Populate the directory.**

   Rsync from a remote source, copy from another NFS path, or let the granted user upload via the NC web UI after step 5. Example rsync:

   ```bash
   rsync -avP --info=progress2 user@source:/path/ /srv/nfs/<archive-name>/
   ```

3. **Add a manifest entry.**

   Edit `infra/stacks/nextcloud/external_storage.tf`. In the `kubernetes_config_map_v1.nextcloud_external_storage_manifest` resource, append a new entry to `archiveMounts`:

   ```json
   { "mountPoint": "/<archive-name>", "dataDir": "/mnt/pve-nfs/<archive-name>", "applicableUsers": ["<owner1>", "admin"], "applicableGroups": [], "enableSharing": false }
   ```

   Use `/mnt/pve-nfs-ssd/<archive-name>` for the SSD pool. NC usernames are `admin`, `anca`, `emo` — not display names (`admin` is Viktor). `admin` is included so the owner of the homelab can always assist with the archive. Set `enableSharing: true` only if you want recipients to re-share subfolders.

4. **Plan and apply.**

   ```bash
   cd infra/stacks/nextcloud
   scripts/tg plan
   scripts/tg apply
   ```

   The bootstrap Job re-runs and applies the new mount plus `applicable_users` idempotently via `occ files_external:*` and `occ files_external:applicable`. No manual `occ` invocation needed.

5. **Verify.**

   Log in as a granted user — `/<archive-name>` must appear in their NC sidebar; read, upload, and delete must all work. Log in as a non-granted user and confirm the mount is not visible at all.

## Backout

Remove the entry from `archiveMounts` in the manifest ConfigMap, then `scripts/tg apply`. The bootstrap Job re-runs and removes the mount. The root mounts (`PVE NFS Pool`, `PVE NFS-SSD Pool`, visible to group `admin` only) are unaffected throughout.

After the mount is gone there is no NC trash to clean. The directory on PVE (`/srv/nfs/<archive-name>`) can be `rmdir`'d once you have confirmed the data is safe elsewhere.

## Related

- Architecture: `docs/architecture/storage.md` — "Nextcloud as PVE-NFS browser" section
- Original design/plan: `infra/docs/plans/2026-05-23-anca-elements-{design,plan}.md` <!-- TODO: confirm path once orchestrator files the plan docs -->
- Manifest source: `infra/stacks/nextcloud/external_storage.tf` (`kubernetes_config_map_v1.nextcloud_external_storage_manifest`)
