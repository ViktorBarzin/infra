# Runbook: Restore PVC from LVM Thin Snapshot

Last updated: 2026-04-06

## When to Use

- Rolling back a PVC to a previous state after a bad migration, data corruption, or accidental deletion
- Pre-upgrade safety: snapshot before upgrade, restore if upgrade fails
- Fast recovery for data changed within the last 7 days

## Prerequisites

- SSH access to PVE host (192.168.1.127)
- The `lvm-pvc-snapshot` script at `/usr/local/bin/lvm-pvc-snapshot`
- kubectl configured on PVE host (`/root/.kube/config`)

## Snapshot Retention

- **Daily snapshots**: Created at 03:00 via systemd timer
- **Retention**: 7 days (older snapshots automatically pruned)
- **Coverage**: All proxmox-lvm PVCs except `dbaas` and `monitoring` namespaces

**If you need data older than 7 days**, see "Alternative: Restore from sda Backup" below.

## Procedure

### 1. List Available Snapshots

```bash
ssh root@192.168.1.127 lvm-pvc-snapshot list
```

Output shows all snapshots with their original LV, age, and data divergence percentage.

### 2. Identify the PVC LV Name

Find the LV name for your PVC:

```bash
# From your workstation (with kubectl):
kubectl get pv -o custom-columns='PV:.metadata.name,PVC:.spec.claimRef.name,NS:.spec.claimRef.namespace,HANDLE:.spec.csi.volumeHandle'

# The HANDLE column shows "local-lvm:<lv-name>"
```

### 3. Run the Restore

```bash
ssh root@192.168.1.127
lvm-pvc-snapshot restore <pvc-lv-name> <snapshot-lv-name>
```

The script will:
1. Look up the K8s PV/PVC/workload for the LV
2. Show a dry-run of all actions
3. Ask for confirmation (type `yes`)
4. Scale down the workload (Deployment or StatefulSet)
5. Rename the current LV to `<name>_pre_restore_<timestamp>`
6. Rename the snapshot LV to the original name
7. Scale the workload back up
8. Wait for pod to become Ready

### 4. Verify

```bash
# Check pod is running
kubectl get pods -n <namespace> -l app=<workload>

# Check the application is working correctly
# (service-specific verification)
```

### 5. Clean Up

Once you've verified the restore is correct, remove the pre-restore backup:

```bash
ssh root@192.168.1.127 lvremove -f pve/<original-lv>_pre_restore_<timestamp>
```

## Manual Restore (if script fails)

If the automated restore fails, perform these steps manually:

```bash
# 1. Scale down the workload
kubectl scale deployment/<name> -n <ns> --replicas=0
# or for StatefulSets:
kubectl scale statefulset/<name> -n <ns> --replicas=0

# 2. Wait for pods to terminate
kubectl wait --for=delete pod -l app=<name> -n <ns> --timeout=120s

# 3. SSH to PVE host
ssh root@192.168.1.127

# 4. Verify LV is inactive
lvs -o lv_name,lv_active pve | grep <lv-name>

# 5. Rename LVs
lvrename pve <original-lv> <original-lv>_pre_restore_$(date +%Y%m%d_%H%M)
lvrename pve <snapshot-lv> <original-lv>

# 6. Scale back up
kubectl scale deployment/<name> -n <ns> --replicas=1
```

## Database-Specific Notes

- **MySQL InnoDB**: After restore, InnoDB will replay redo logs automatically on startup. Check `SHOW ENGINE INNODB STATUS` for recovery progress.
- **PostgreSQL**: WAL replay happens automatically. Check `pg_is_in_recovery()` and PostgreSQL logs.
- **Redis**: Redis loads the RDB file on startup. Check `INFO persistence` for load status.

For databases, prefer the app-level backup restore (see `restore-mysql.md`, `restore-postgresql.md`) unless you need a very recent point-in-time that predates the last dump.

## Alternative: Restore from sda Backup

If LVM snapshots are too old or missing (data lost >7 days ago), use the weekly file-level backup on sda:

**Location**: `/mnt/backup/pvc-data/<YYYY-WW>/<namespace>/<pvc-name>/` on PVE host
**Retention**: 4 weekly versions (weeks 0-3)

### Procedure

```bash
# 1. List available backup weeks
ssh root@192.168.1.127
ls -l /mnt/backup/pvc-data/

# 2. Identify the PVC backup directory
ls -l /mnt/backup/pvc-data/2026-14/<namespace>/

# 3. Scale down the workload
kubectl scale deployment/<name> -n <ns> --replicas=0

# 4. Mount the live PVC LV on PVE host
lvchange -ay pve/<pvc-lv-name>
mkdir -p /mnt/restore-temp
mount /dev/pve/<pvc-lv-name> /mnt/restore-temp

# 5. Restore from backup
rsync -avP --delete /mnt/backup/pvc-data/2026-14/<namespace>/<pvc-name>/ /mnt/restore-temp/

# 6. Unmount and scale up
umount /mnt/restore-temp
lvchange -an pve/<pvc-lv-name>
kubectl scale deployment/<name> -n <ns> --replicas=1
```

See `restore-pvc-from-backup.md` for detailed walkthrough.

## Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| "Another instance is running" | Concurrent snapshot/restore | Wait for timer to finish: `systemctl status lvm-pvc-snapshot.service` |
| LV still active after scale-down | Proxmox CSI hasn't detached | Wait 30s, or `lvchange -an pve/<lv>` |
| Pod stuck in ContainerCreating | Volume not attached to node | `kubectl describe pod` — check events for attach errors |
| No PV found for volume handle | LV name doesn't match any PV | Check `kubectl get pv -o yaml` for the correct volumeHandle format |
