# Restore Vaultwarden

Last updated: 2026-04-06

## Prerequisites
- `kubectl` access to the cluster
- Backup available on NFS at `/mnt/main/vaultwarden-backup/`

## Backup Location
- NFS: `/mnt/main/vaultwarden-backup/YYYY_MM_DD_HH_MM/` (directory per backup)
- Each backup contains: `db.sqlite3`, `rsa_key.pem`, `rsa_key.pub.pem`, `attachments/`, `sends/`, `config.json`
- Mirrored to sda: `/mnt/backup/nfs-mirror/vaultwarden-backup/` (PVE host 192.168.1.127)
- PVC file backup (alternative): `/mnt/backup/pvc-data/<YYYY-WW>/vaultwarden/vaultwarden-data-proxmox/`
- Replicated to Synology NAS: `Synology/Backup/Viki/pve-backup/nfs-mirror/vaultwarden-backup/`
- Retention: 30 days (on NFS), latest only (on sda nfs-mirror), 4 weeks (on sda pvc-data), unlimited (on Synology)
- Schedule: Every 6 hours (00:00, 06:00, 12:00, 18:00)
- Integrity check: Both source and backup are verified before/after each backup

## Backup Contents
| File | Purpose | Critical? |
|------|---------|-----------|
| `db.sqlite3` | All passwords, TOTP seeds, org data | Yes |
| `rsa_key.pem` / `rsa_key.pub.pem` | JWT signing keys | Yes — without these, all sessions invalidate |
| `attachments/` | File attachments on vault items | Yes |
| `sends/` | Bitwarden Send files | No |
| `config.json` | Server configuration | No — can be recreated |

## Restore Procedure

### 1. Identify the backup to restore
```bash
# List available backups (directories sorted by date)
kubectl run vw-ls --rm -it --image=alpine \
  --overrides='{"spec":{"volumes":[{"name":"backup","persistentVolumeClaim":{"claimName":"vaultwarden-backup"}}],"containers":[{"name":"vw-ls","image":"alpine","volumeMounts":[{"name":"backup","mountPath":"/backup"}],"command":["ls","-lt","/backup/"]}]}}' \
  -n vaultwarden
```

### 2. Scale down Vaultwarden
```bash
kubectl scale deployment vaultwarden -n vaultwarden --replicas=0
```

### 3. Restore the backup
```bash
BACKUP_DIR="YYYY_MM_DD_HH_MM"  # Set to desired backup

kubectl run vw-restore --rm -it --image=alpine \
  --overrides='{"spec":{"volumes":[{"name":"backup","persistentVolumeClaim":{"claimName":"vaultwarden-backup"}},{"name":"data","persistentVolumeClaim":{"claimName":"vaultwarden-data-proxmox"}}],"containers":[{"name":"vw-restore","image":"alpine","volumeMounts":[{"name":"backup","mountPath":"/backup"},{"name":"data","mountPath":"/data"}],"command":["/bin/sh","-c","cp /backup/'$BACKUP_DIR'/db.sqlite3 /data/db.sqlite3 && cp /backup/'$BACKUP_DIR'/rsa_key.pem /data/ && cp /backup/'$BACKUP_DIR'/rsa_key.pub.pem /data/ && cp -a /backup/'$BACKUP_DIR'/attachments /data/ 2>/dev/null; echo Restore complete"]}]}}' \
  -n vaultwarden
```

### 4. Scale up Vaultwarden
```bash
kubectl scale deployment vaultwarden -n vaultwarden --replicas=1

# Wait for pod to be ready
kubectl wait --for=condition=Ready pod -l app=vaultwarden -n vaultwarden --timeout=120s
```

### 5. Verify restoration
```bash
# Check pod logs for startup errors
kubectl logs -n vaultwarden -l app=vaultwarden --tail=20

# Test web UI access
curl -s -o /dev/null -w "%{http_code}" https://vaultwarden.viktorbarzin.me/
```

### 6. Test login
Log in to the Vaultwarden web UI and verify:
- [ ] Can log in with your account
- [ ] Vault items are present and readable
- [ ] Attachments are accessible
- [ ] TOTP codes are generating correctly

## Alternative: Restore from PVC File Backup

If the NFS backup is unavailable or corrupt, restore from the weekly PVC file backup on sda:

```bash
# 1. List available backup weeks
ssh root@192.168.1.127
ls -l /mnt/backup/pvc-data/

# 2. Scale down Vaultwarden
kubectl scale deployment vaultwarden -n vaultwarden --replicas=0

# 3. Mount the live PVC LV on PVE host
# Find the LV name first:
kubectl get pv -o custom-columns='PV:.metadata.name,PVC:.spec.claimRef.name,HANDLE:.spec.csi.volumeHandle' | grep vaultwarden-data-proxmox
# Assuming volumeHandle is "local-lvm:vm-999-pvc-abc123"
LV_NAME="vm-999-pvc-abc123"

lvchange -ay pve/$LV_NAME
mkdir -p /mnt/restore-temp
mount /dev/pve/$LV_NAME /mnt/restore-temp

# 4. Restore from backup (pick a week)
rsync -avP --delete /mnt/backup/pvc-data/2026-14/vaultwarden/vaultwarden-data-proxmox/ /mnt/restore-temp/

# 5. Unmount and scale up
umount /mnt/restore-temp
lvchange -an pve/$LV_NAME
kubectl scale deployment vaultwarden -n vaultwarden --replicas=1
```

## Alternative: Restore from sda Backup Mirror

If the Proxmox host NFS mount is unavailable but the PVE host itself is accessible:

```bash
# 1. SSH to PVE host
ssh root@192.168.1.127

# 2. Find the latest backup
ls -lt /mnt/backup/nfs-mirror/vaultwarden-backup/

# 3. Mount sda backup on a pod
BACKUP_DIR="YYYY_MM_DD_HH_MM"  # Set to desired backup

kubectl run vw-restore --rm -it --image=alpine \
  --overrides='{"spec":{"volumes":[{"name":"backup","hostPath":{"path":"/mnt/backup/nfs-mirror/vaultwarden-backup"}},{"name":"data","persistentVolumeClaim":{"claimName":"vaultwarden-data-proxmox"}}],"containers":[{"name":"vw-restore","image":"alpine","volumeMounts":[{"name":"backup","mountPath":"/backup"},{"name":"data","mountPath":"/data"}],"command":["/bin/sh","-c","cp /backup/'$BACKUP_DIR'/db.sqlite3 /data/db.sqlite3 && cp /backup/'$BACKUP_DIR'/rsa_key.pem /data/ && cp /backup/'$BACKUP_DIR'/rsa_key.pub.pem /data/ && cp -a /backup/'$BACKUP_DIR'/attachments /data/ 2>/dev/null; echo Restore complete"]}],"nodeName":"k8s-master"}}' \
  -n vaultwarden
```

## Estimated Time
- Restore: ~5 minutes
- Verification: ~5 minutes
