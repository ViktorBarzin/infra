# Restore MySQL (InnoDB Cluster)

## Prerequisites
- `kubectl` access to the cluster
- MySQL root password (from `cluster-secret` in `dbaas` namespace, key `ROOT_PASSWORD`)
- Backup dump available on NFS at `/mnt/main/mysql-backup/`

## Backup Location
- NFS: `/mnt/main/mysql-backup/dump_YYYY_MM_DD_HH_MM.sql`
- Replicated to Synology NAS (192.168.1.13) via TrueNAS ZFS replication
- Retention: 14 days
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

# Restore (use --host to avoid unix socket, specify non-default port)
mysql -u root -p"$ROOT_PWD" --host 127.0.0.1 --port 3307 < /path/to/dump_YYYY_MM_DD_HH_MM.sql
```

### 3. Option B: Restore via in-cluster pod
```bash
ROOT_PWD=$(kubectl get secret cluster-secret -n dbaas -o jsonpath='{.data.ROOT_PASSWORD}' | base64 -d)

kubectl run mysql-restore --rm -it --image=mysql \
  --overrides='{"spec":{"volumes":[{"name":"backup","persistentVolumeClaim":{"claimName":"dbaas-mysql-backup"}}],"containers":[{"name":"mysql-restore","image":"mysql","env":[{"name":"MYSQL_PWD","value":"'$ROOT_PWD'"}],"volumeMounts":[{"name":"backup","mountPath":"/backup"}],"command":["mysql","-u","root","--host","mysql.dbaas.svc.cluster.local","<","/backup/dump_YYYY_MM_DD_HH_MM.sql"]}]}}' \
  -n dbaas
```

### 4. Verify restoration
```bash
# Check databases exist
mysql -u root -p"$ROOT_PWD" --host 127.0.0.1 --port 3307 -e "SHOW DATABASES;"

# Check InnoDB Cluster status
mysql -u root -p"$ROOT_PWD" --host 127.0.0.1 --port 3307 -e "SELECT * FROM performance_schema.replication_group_members;"

# Check table counts for key databases
for db in speedtest wrongmove codimd nextcloud shlink grafana; do
  echo "=== $db ==="
  mysql -u root -p"$ROOT_PWD" --host 127.0.0.1 --port 3307 -e "SELECT TABLE_NAME, TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA='$db' ORDER BY TABLE_ROWS DESC LIMIT 5;"
done
```

### 5. InnoDB Cluster Recovery
If the InnoDB Cluster itself is broken (not just data loss):
```bash
# Check cluster status via MySQL Shell
kubectl exec -it mysql-cluster-0 -n dbaas -c mysql -- mysqlsh root@localhost --password="$ROOT_PWD" -- cluster status

# Force rejoin a member
kubectl exec -it mysql-cluster-0 -n dbaas -c mysql -- mysqlsh root@localhost --password="$ROOT_PWD" -- cluster rejoinInstance root@mysql-cluster-1:3306
```

## Estimated Time
- Data restore: ~5 minutes (11MB dump)
- InnoDB Cluster recovery: ~15-20 minutes (init containers are slow)
