# NFS Prerequisites for `modules/kubernetes/nfs_volume`

The `nfs_volume` Terraform module creates a `PersistentVolume` pointing at a
path on the Proxmox NFS server (`192.168.1.127`). It does **not** create the
underlying directory on the server.

If the path does not exist, the first pod that tries to mount the resulting
PVC gets stuck in `ContainerCreating` with the kubelet event:

```
MountVolume.SetUp failed for volume "<name>" : mount failed: exit status 32
mount.nfs: mounting 192.168.1.127:/srv/nfs/<path> failed, reason given by
server: No such file or directory
```

## Bootstrap before first apply

Before adding a new `nfs_volume` consumer (backup CronJob, data PV, etc.),
create the export root on the PVE host:

```sh
# Replace <app> with the backup stack name, e.g. mailserver-backup,
# roundcube-backup, immich-backup, etc.
ssh root@192.168.1.127 'mkdir -p /srv/nfs/<app> && chmod 755 /srv/nfs/<app>'

# Confirm exports are live (no change to /etc/exports needed — `/srv/nfs`
# is already exported via the root entry in pve-nfs-exports).
ssh root@192.168.1.127 exportfs -v | grep '/srv/nfs\b'
```

`/srv/nfs` is exported with the root entry. Subdirectories inherit the
export automatically; they just have to exist on disk.

## Known consumers

| Consumer                       | NFS path                        | Owning stack            |
|--------------------------------|---------------------------------|--------------------------|
| `mailserver-backup`            | `/srv/nfs/mailserver-backup`    | `stacks/mailserver/`    |
| `roundcube-backup`             | `/srv/nfs/roundcube-backup`     | `stacks/mailserver/`    |
| `mysql-backup`                 | `/srv/nfs/mysql-backup`         | `stacks/dbaas/`         |
| `postgresql-backup`            | `/srv/nfs/postgresql-backup`    | `stacks/dbaas/`         |
| `vaultwarden-backup`           | `/srv/nfs/vaultwarden-backup`   | `stacks/vaultwarden/`   |

Use `grep -rn 'nfs_volume' infra/stacks/` to find all active consumers.

## Why not auto-create?

Two options were considered for automating this:

1. `null_resource` + `local-exec` SSH `mkdir` in the `nfs_volume` module —
   works but adds an SSH dependency to every Terraform run, makes the
   module non-hermetic, and fails if the operator does not have SSH to
   the PVE host.
2. `nfs-subdir-external-provisioner` — handles subdirs automatically but
   changes the PV/PVC shape and would require migrating all existing
   consumers.

Neither is worth the churn for a one-time operation per new backup stack.
Document + checklist is the current call; re-evaluate if we start adding
one NFS consumer per week.

## Related tasks

- `code-yo4` — this runbook
- `code-z26` — mailserver backup CronJob (first-time setup hit this)
- `code-1f6` — Roundcube backup CronJob (also hit this)
