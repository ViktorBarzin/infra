# Runbook: Restore PVC from sda File Backup

Last updated: 2026-04-06

## When to Use

- LVM snapshots are too old (>7 days) or missing
- Need to restore data from a specific week (up to 4 weeks back)
- LVM snapshot restore failed or snapshot is corrupt
- Granular file-level restore (not full PVC)

## Prerequisites

- SSH access to PVE host (192.168.1.127)
- kubectl configured (either on PVE host or your workstation)
- sda backup disk mounted at `/mnt/backup` on PVE host

## Backup Location

**Path**: `/mnt/backup/pvc-data/<YYYY-WW>/<namespace>/<pvc-name>/` on PVE host
**Retention**: 4 weekly versions (weeks 0-3)
**Deduplication**: `--link-dest` hardlink dedup (unchanged files share inodes across weeks)

## Procedure

### 1. List Available Backup Weeks

```bash
ssh root@192.168.1.127
ls -l /mnt/backup/pvc-data/

# Output shows week directories like:
# 2026-13
# 2026-14
# 2026-15
# 2026-16
```

### 2. Identify the PVC Backup Directory

```bash
# List namespaces in a specific week
ls -l /mnt/backup/pvc-data/2026-14/

# List PVCs in a namespace
ls -l /mnt/backup/pvc-data/2026-14/vaultwarden/

# Example: vaultwarden-data-proxmox/
```

### 3. Find the Live PVC LV Name

From your workstation (or PVE host with kubectl):

```bash
# Get the PV volumeHandle (contains LV name)
kubectl get pv -o custom-columns='PV:.metadata.name,PVC:.spec.claimRef.name,NS:.spec.claimRef.namespace,HANDLE:.spec.csi.volumeHandle' | grep <pvc-name>

# Example output:
# pvc-abc123  vaultwarden-data-proxmox  vaultwarden  local-lvm:vm-999-pvc-abc123
#                                                                   ↑ this is the LV name
```

### 4. Scale Down the Workload

```bash
# Find the workload using the PVC
kubectl get deployment,statefulset -n <namespace> -o json | jq '.items[] | select(.spec.template.spec.volumes[]?.persistentVolumeClaim.claimName == "<pvc-name>") | .metadata.name'

# Scale down (Deployment example)
kubectl scale deployment/<workload-name> -n <namespace> --replicas=0

# Or StatefulSet:
kubectl scale statefulset/<workload-name> -n <namespace> --replicas=0

# Wait for pod to terminate
kubectl wait --for=delete pod -l app=<workload-name> -n <namespace> --timeout=120s
```

### 5. Mount the Live PVC LV

```bash
ssh root@192.168.1.127

# Activate the LV (should already be inactive after pod termination)
lvchange -ay pve/<lv-name>

# Create mount point
mkdir -p /mnt/restore-temp

# Mount the LV
mount /dev/pve/<lv-name> /mnt/restore-temp
```

### 6. Restore from Backup

**Option A: Full PVC restore (replace all data)**

```bash
# This will delete existing files in the PVC and replace with backup
rsync -avP --delete /mnt/backup/pvc-data/<YYYY-WW>/<namespace>/<pvc-name>/ /mnt/restore-temp/

# Example:
rsync -avP --delete /mnt/backup/pvc-data/2026-14/vaultwarden/vaultwarden-data-proxmox/ /mnt/restore-temp/
```

**Option B: Selective file restore (merge)**

```bash
# Restore specific files or directories without deleting existing data
rsync -avP /mnt/backup/pvc-data/<YYYY-WW>/<namespace>/<pvc-name>/path/to/file /mnt/restore-temp/path/to/

# Example: Restore only db.sqlite3
rsync -avP /mnt/backup/pvc-data/2026-14/vaultwarden/vaultwarden-data-proxmox/db.sqlite3 /mnt/restore-temp/
```

### 7. Unmount and Deactivate LV

```bash
# Unmount
umount /mnt/restore-temp

# Deactivate LV (optional, kubelet will activate it when pod starts)
lvchange -an pve/<lv-name>
```

### 8. Scale Up the Workload

```bash
# From your workstation:
kubectl scale deployment/<workload-name> -n <namespace> --replicas=1

# Or StatefulSet:
kubectl scale statefulset/<workload-name> -n <namespace> --replicas=1

# Wait for pod to be ready
kubectl wait --for=condition=Ready pod -l app=<workload-name> -n <namespace> --timeout=120s
```

### 9. Verify

```bash
# Check pod logs for startup errors
kubectl logs -n <namespace> -l app=<workload-name> --tail=20

# Test application functionality (service-specific)
curl -s -o /dev/null -w "%{http_code}" https://<service>.viktorbarzin.me/
```

## Example: Full Vaultwarden Restore

```bash
# 1. List backups
ssh root@192.168.1.127
ls -l /mnt/backup/pvc-data/

# 2. Scale down
kubectl scale deployment vaultwarden -n vaultwarden --replicas=0
kubectl wait --for=delete pod -l app=vaultwarden -n vaultwarden --timeout=120s

# 3. Find LV name
kubectl get pv -o custom-columns='PV:.metadata.name,PVC:.spec.claimRef.name,HANDLE:.spec.csi.volumeHandle' | grep vaultwarden-data-proxmox
# Output: pvc-xyz  vaultwarden-data-proxmox  local-lvm:vm-105-pvc-xyz456

# 4. Mount and restore
ssh root@192.168.1.127
lvchange -ay pve/vm-105-pvc-xyz456
mkdir -p /mnt/restore-temp
mount /dev/pve/vm-105-pvc-xyz456 /mnt/restore-temp

rsync -avP --delete /mnt/backup/pvc-data/2026-14/vaultwarden/vaultwarden-data-proxmox/ /mnt/restore-temp/

umount /mnt/restore-temp
lvchange -an pve/vm-105-pvc-xyz456

# 5. Scale up
kubectl scale deployment vaultwarden -n vaultwarden --replicas=1
kubectl wait --for=condition=Ready pod -l app=vaultwarden -n vaultwarden --timeout=120s

# 6. Test
curl -s -o /dev/null -w "%{http_code}" https://vaultwarden.viktorbarzin.me/
```

## Database-Specific Notes

For databases (MySQL, PostgreSQL), prefer the app-level backup restore (see `restore-mysql.md`, `restore-postgresql.md`) unless:
- You need a very recent point-in-time that predates the last dump
- The database dump is corrupt or missing
- You're restoring a non-SQL database (e.g., Redis RDB)

## Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| "LV is active" during mount | Workload pod still running or stuck | `kubectl get pods -A | grep <pvc-name>`, delete pod if stuck |
| "No such file or directory" in backup | PVC not backed up (in excluded namespace) | Check `daily-backup` script EXCLUDE_NAMESPACES |
| rsync shows 0 files transferred | Wrong backup week or PVC name | Double-check paths: `ls /mnt/backup/pvc-data/<week>/<ns>/<pvc>/` |
| Pod stuck in ContainerCreating after restore | LV still active on PVE host | `lvchange -an pve/<lv-name>`, wait 30s, check pod again |
| Backup week missing | Daily backup hasn't run for that week | Check `systemctl status daily-backup.service`, verify retention |

## Restore from Synology (if PVE host sda is unavailable)

If the PVE host sda backup disk is unavailable or corrupt:

```bash
# 1. SSH to Synology NAS
ssh Administrator@192.168.1.13

# 2. Navigate to backup directory
cd /volume1/Backup/Viki/pve-backup/pvc-data/

# 3. Find the PVC backup
ls -l 2026-14/<namespace>/<pvc-name>/

# 4. Copy to a temporary location accessible from cluster
# Option A: Restore sda on PVE host first
# Option B: rsync to a surviving node's local disk
# Option C: Mount Synology NFS share on a pod (if network accessible)
```

## Estimated Time

- Small PVC (<1GB): ~5 minutes
- Medium PVC (1-10GB): ~10-15 minutes
- Large PVC (>10GB): ~30+ minutes (depends on size and network)

## Related

- **`restore-lvm-snapshot.md`** — Fast restore for recent changes (<7 days)
- **`restore-full-cluster.md`** — Disaster recovery procedure (uses this runbook in Phase 3.5)
- **`docs/architecture/backup-dr.md`** — Backup architecture overview
