# Restore Vaultwarden

## Prerequisites
- `kubectl` access to the cluster
- Backup available on NFS at `/mnt/main/vaultwarden-backup/`

## Backup Location
- NFS: `/mnt/main/vaultwarden-backup/YYYY_MM_DD_HH_MM/` (directory per backup)
- Each backup contains: `db.sqlite3`, `rsa_key.pem`, `rsa_key.pub.pem`, `attachments/`, `sends/`, `config.json`
- Replicated to Synology NAS (192.168.1.13) via TrueNAS ZFS replication
- Retention: 30 days
- Schedule: Daily at 00:00

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
  --overrides='{"spec":{"volumes":[{"name":"backup","persistentVolumeClaim":{"claimName":"vaultwarden-backup"}},{"name":"data","persistentVolumeClaim":{"claimName":"vaultwarden-data"}}],"containers":[{"name":"vw-restore","image":"alpine","volumeMounts":[{"name":"backup","mountPath":"/backup"},{"name":"data","mountPath":"/data"}],"command":["/bin/sh","-c","cp /backup/'$BACKUP_DIR'/db.sqlite3 /data/db.sqlite3 && cp /backup/'$BACKUP_DIR'/rsa_key.pem /data/ && cp /backup/'$BACKUP_DIR'/rsa_key.pub.pem /data/ && cp -a /backup/'$BACKUP_DIR'/attachments /data/ 2>/dev/null; echo Restore complete"]}]}}' \
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

## Estimated Time
- Restore: ~5 minutes
- Verification: ~5 minutes
