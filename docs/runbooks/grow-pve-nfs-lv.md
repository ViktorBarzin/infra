# Runbook: Grow `/srv/nfs` LV (`pve/nfs-data`)

Use when `/srv/nfs` on the PVE host is filling up and the workloads writing to it cannot be slimmed down. The LV sits on the LVM-thin pool `pve/data` (10.54 TB total). Thin-pool free space is the real gate — confirm before extending.

## When to use

- `df -h /srv/nfs` shows usage > ~85 % and projected growth exceeds free space within a backup retention window.
- An upcoming bulk write (media import, restore) needs headroom that the current free space won't absorb.

## Steps

1. **Check thin-pool headroom on PVE host:**

   ```bash
   ssh root@192.168.1.127 'lvs pve/data; lvs pve/nfs-data; df -h /srv/nfs'
   ```

   The `pve/data` thin pool's `Data%` should leave room for the extension (target `Data%` after extend < 90 %).

2. **Extend the LV and online-resize ext4:**

   ```bash
   ssh root@192.168.1.127 '
     lvextend -L +1T pve/nfs-data &&
     resize2fs /dev/pve/nfs-data
   '
   ```

   Both commands are safe online: `lvextend` only grows allocation, `resize2fs` extends ext4 while mounted.

3. **Verify:**

   ```bash
   ssh root@192.168.1.127 'lvs pve/nfs-data; df -h /srv/nfs'
   ```

   `df` should show the new size; `Use%` should drop proportionally.

## Notes

- **Not Terraform-managed.** PVE host LVs live outside the IaC tree (no `infra/stacks/pve-host/`). Record the new size in `docs/architecture/storage.md` (the "HDD NFS" line and the diagram label) in the same commit.
- **Thin-pool overcommit warning** from `lvextend` is informational — it reports the sum of all thin volume virtual sizes (currently ~12 TiB) vs. the physical pool (10.7 TiB). Real fill is `pve/data` `Data%`; ignore the overcommit warning unless `Data%` itself is climbing toward 100 %.
- **`/srv/nfs-ssd`** lives on a separate LV (`ssd/nfs-ssd-data`) backed by SSDs — the same `lvextend`/`resize2fs` pattern applies, but the source pool is `ssd/data`.

## Backout

Online shrinks are unsafe with active workloads. Don't try to shrink `pve/nfs-data` in place — restore from snapshot or migrate data out and rebuild the LV instead.
