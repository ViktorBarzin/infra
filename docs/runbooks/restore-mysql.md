# Restore MySQL (InnoDB Cluster)

Last updated: 2026-04-06

## Prerequisites
- `kubectl` access to the cluster
- MySQL root password (from `cluster-secret` in `dbaas` namespace, key `ROOT_PASSWORD`)
- Backup dump available on NFS at `/mnt/main/mysql-backup/`

## Backup Location
- NFS: `/mnt/main/mysql-backup/dump_YYYY_MM_DD_HH_MM.sql.gz`
- Mirrored to sda: `/mnt/backup/nfs-mirror/mysql-backup/` (PVE host 192.168.1.127)
- Replicated to Synology NAS: `Synology/Backup/Viki/pve-backup/nfs-mirror/mysql-backup/`
- Retention: 14 days (on NFS), latest only (on sda), unlimited (on Synology)
- Size: ~11MB per dump

## Restore Procedure

### 1. Identify the backup to restore
```bash
# List available backups
kubectl run mysql-ls --rm -it --image=mysql \
  --overrides='{"spec":{"volumes":[{"name":"backup","persistentVolumeClaim":{"claimName":"dbaas-mysql-backup"}}],"containers":[{"name":"mysql-ls","image":"mysql","volumeMounts":[{"name":"backup","mountPath":"/backup"}],"command":["ls","-lt","/backup/"]}]}}' \
  -n dbaas
```

### 2. Get the root password
```bash
kubectl get secret cluster-secret -n dbaas -o jsonpath='{.data.ROOT_PASSWORD}' | base64 -d
```

### 3. Option A: Restore via port-forward (from outside cluster)
```bash
# Port-forward to MySQL primary
kubectl port-forward svc/mysql -n dbaas 3307:3306 &

# Get root password
ROOT_PWD=$(kubectl get secret cluster-secret -n dbaas -o jsonpath='{.data.ROOT_PASSWORD}' | base64 -d)

# Restore (decompress and pipe to mysql, use --host to avoid unix socket, specify non-default port)
zcat /path/to/dump_YYYY_MM_DD_HH_MM.sql.gz | mysql -u root -p"$ROOT_PWD" --host 127.0.0.1 --port 3307
```

### 3. Option B: Restore via in-cluster pod
```bash
ROOT_PWD=$(kubectl get secret cluster-secret -n dbaas -o jsonpath='{.data.ROOT_PASSWORD}' | base64 -d)

kubectl run mysql-restore --rm -it --image=mysql \
  --overrides='{"spec":{"volumes":[{"name":"backup","persistentVolumeClaim":{"claimName":"dbaas-mysql-backup"}}],"containers":[{"name":"mysql-restore","image":"mysql","env":[{"name":"MYSQL_PWD","value":"'$ROOT_PWD'"}],"volumeMounts":[{"name":"backup","mountPath":"/backup"}],"command":["/bin/sh","-c","zcat /backup/dump_YYYY_MM_DD_HH_MM.sql.gz | mysql -u root --host mysql.dbaas.svc.cluster.local"]}]}}' \
  -n dbaas
```

### 4. Verify restoration
```bash
# Check databases exist
mysql -u root -p"$ROOT_PWD" --host 127.0.0.1 --port 3307 -e "SHOW DATABASES;"

# Check InnoDB Cluster status
mysql -u root -p"$ROOT_PWD" --host 127.0.0.1 --port 3307 -e "SELECT * FROM performance_schema.replication_group_members;"

# Check table counts for key databases
for db in speedtest wrongmove codimd nextcloud shlink grafana technitium; do
  echo "=== $db ==="
  mysql -u root -p"$ROOT_PWD" --host 127.0.0.1 --port 3307 -e "SELECT TABLE_NAME, TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA='$db' ORDER BY TABLE_ROWS DESC LIMIT 5;"
done
```

### 5. Verify application MySQL users exist

After any cluster rebuild or PVC recreation, the MySQL operator only recreates its own system users. Application users may be lost.

```bash
ROOT_PWD=$(kubectl get secret cluster-secret -n dbaas -o jsonpath='{.data.ROOT_PASSWORD}' | base64 -d)

# Check all expected application users exist
kubectl exec -n dbaas mysql-cluster-0 -c mysql -- mysql -u root -p"$ROOT_PWD" \
  -e "SELECT user, host FROM mysql.user WHERE user IN ('nextcloud','forgejo','crowdsec','grafana','speedtest','wrongmove','codimd','shlink','technitium','uptimekuma');"

# If users are missing, force Vault to re-rotate their credentials:
# vault write -f database/rotate-role/mysql-<app>
# This will recreate the user with the correct password.
#
# For technitium specifically, also run the password sync CronJob:
# kubectl create job --from=cronjob/technitium-password-sync technitium-pw-resync -n technitium
#
# Note: forgejo and uptimekuma may be legacy users not managed by Vault rotation.
```

### 6. InnoDB Cluster Recovery
If the InnoDB Cluster itself is broken (not just data loss):
```bash
# Check cluster status via MySQL Shell
kubectl exec -it mysql-cluster-0 -n dbaas -c mysql -- mysqlsh root@localhost --password="$ROOT_PWD" -- cluster status

# Force rejoin a member
kubectl exec -it mysql-cluster-0 -n dbaas -c mysql -- mysqlsh root@localhost --password="$ROOT_PWD" -- cluster rejoinInstance root@mysql-cluster-1:3306
```

## Restore Single Database (from per-db backup)

Per-database backups are stored at `/mnt/main/mysql-backup/per-db/<dbname>/` as gzipped SQL dumps.

### 1. List available per-db backups
```bash
ls -lt /mnt/main/mysql-backup/per-db/<dbname>/
```

### 2. Restore a single database
```bash
# Port-forward to MySQL
kubectl port-forward svc/mysql -n dbaas 3307:3306 &
ROOT_PWD=$(kubectl get secret cluster-secret -n dbaas -o jsonpath='{.data.ROOT_PASSWORD}' | base64 -d)

# Restore single database (this replaces only the target database)
zcat /path/to/per-db/<dbname>/dump_YYYY_MM_DD_HH_MM.sql.gz | mysql -u root -p"$ROOT_PWD" --host 127.0.0.1 --port 3307 <dbname>
```

### 3. Verify
```bash
mysql -u root -p"$ROOT_PWD" --host 127.0.0.1 --port 3307 -e \
  "SELECT TABLE_NAME, TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA='<dbname>' ORDER BY TABLE_ROWS DESC LIMIT 10;"
```

### 4. Restart the affected service only
```bash
kubectl rollout restart deployment -n <namespace>
```

**Advantages over full restore**: Only the target database is affected. All other databases continue running with their current data.

## Alternative: Restore from sda Backup

If TrueNAS NFS is unavailable but the PVE host is accessible:

```bash
# 1. SSH to PVE host
ssh root@192.168.1.127

# 2. Find the latest backup
ls -lt /mnt/backup/nfs-mirror/mysql-backup/

# 3. Copy backup to a location accessible from cluster (e.g., via kubectl cp)
# Or mount sda backup on a pod:
kubectl run mysql-restore --rm -it --image=mysql \
  --overrides='{"spec":{"volumes":[{"name":"backup","hostPath":{"path":"/mnt/backup/nfs-mirror/mysql-backup"}}],"containers":[{"name":"mysql-restore","image":"mysql","env":[{"name":"MYSQL_PWD","value":"'$ROOT_PWD'"}],"volumeMounts":[{"name":"backup","mountPath":"/backup"}],"command":["/bin/sh","-c","zcat /backup/dump_YYYY_MM_DD_HH_MM.sql.gz | mysql -u root --host mysql.dbaas.svc.cluster.local"]}],"nodeName":"k8s-master"}}' \
  -n dbaas
```

## Alternative: Restore from Synology (if PVE host is down)

If both TrueNAS and PVE host are unavailable:

```bash
# 1. SSH to Synology NAS
ssh Administrator@192.168.1.13

# 2. Navigate to backup directory
cd /volume1/Backup/Viki/pve-backup/nfs-mirror/mysql-backup/

# 3. Copy dump to a temporary location accessible from cluster
# (e.g., via rsync to a surviving node, or restore TrueNAS first)
```

## Estimated Time
- Data restore: ~5 minutes (11MB dump)
- InnoDB Cluster recovery: ~15-20 minutes (init containers are slow)
