# Restore PostgreSQL (CNPG)

## Prerequisites
- `kubectl` access to the cluster
- CNPG operator running in the cluster
- Backup dump available on NFS at `/mnt/main/postgresql-backup/`
- PostgreSQL superuser password (from `pg-cluster-superuser` secret in `dbaas` namespace)

## Backup Location
- NFS: `/mnt/main/postgresql-backup/dump_YYYY_MM_DD_HH_MM.sql`
- Replicated to Synology NAS (192.168.1.13) via TrueNAS ZFS replication
- Retention: 14 days

## Restore from pg_dumpall

### 1. Identify the backup to restore
```bash
# List available backups (from any node with NFS access)
ls -lt /mnt/main/postgresql-backup/dump_*.sql | head -20

# Or via a pod:
kubectl run pg-restore --rm -it --image=postgres:16.4-bullseye \
  --overrides='{"spec":{"volumes":[{"name":"backup","persistentVolumeClaim":{"claimName":"dbaas-postgresql-backup"}}],"containers":[{"name":"pg-restore","image":"postgres:16.4-bullseye","volumeMounts":[{"name":"backup","mountPath":"/backup"}],"command":["ls","-lt","/backup/"]}]}}' \
  -n dbaas
```

### 2. Get the superuser password
```bash
kubectl get secret pg-cluster-superuser -n dbaas -o jsonpath='{.data.password}' | base64 -d
```

### 3. Option A: Restore into existing CNPG cluster
```bash
# Port-forward to the CNPG primary
kubectl port-forward svc/pg-cluster-rw -n dbaas 5433:5432 &

# Restore (this will overwrite existing data)
PGPASSWORD=$(kubectl get secret pg-cluster-superuser -n dbaas -o jsonpath='{.data.password}' | base64 -d) \
  psql -h 127.0.0.1 -p 5433 -U postgres -f /path/to/dump_YYYY_MM_DD_HH_MM.sql
```

### 3. Option B: Rebuild CNPG cluster from scratch
```bash
# 1. Delete the existing cluster
kubectl delete cluster pg-cluster -n dbaas

# 2. Wait for PVCs to be cleaned up
kubectl get pvc -n dbaas -l cnpg.io/cluster=pg-cluster

# 3. Re-apply the cluster manifest (via terragrunt)
cd infra && scripts/tg apply -target=null_resource.pg_cluster stacks/dbaas

# 4. Wait for cluster to be ready
kubectl wait --for=condition=Ready cluster/pg-cluster -n dbaas --timeout=300s

# 5. Restore the dump
PGPASSWORD=$(kubectl get secret pg-cluster-superuser -n dbaas -o jsonpath='{.data.password}' | base64 -d) \
  kubectl run pg-restore --rm -it --image=postgres:16.4-bullseye \
  --overrides='{"spec":{"volumes":[{"name":"backup","persistentVolumeClaim":{"claimName":"dbaas-postgresql-backup"}}],"containers":[{"name":"pg-restore","image":"postgres:16.4-bullseye","env":[{"name":"PGPASSWORD","value":"'$PGPASSWORD'"}],"volumeMounts":[{"name":"backup","mountPath":"/backup"}],"command":["psql","-h","pg-cluster-rw.dbaas","-U","postgres","-f","/backup/dump_YYYY_MM_DD_HH_MM.sql"]}]}}' \
  -n dbaas
```

### 4. Verify restoration
```bash
# Check databases exist
PGPASSWORD=$PGPASSWORD psql -h 127.0.0.1 -p 5433 -U postgres -c "\l"

# Check table counts for critical databases
for db in trading health linkwarden affine woodpecker claude_memory; do
  echo "=== $db ==="
  PGPASSWORD=$PGPASSWORD psql -h 127.0.0.1 -p 5433 -U postgres -d $db -c \
    "SELECT schemaname, tablename, n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC LIMIT 5;"
done
```

### 5. Restart dependent services
After restore, restart services that connect to PostgreSQL to pick up fresh connections:
```bash
kubectl rollout restart deployment -n trading
kubectl rollout restart deployment -n health
kubectl rollout restart deployment -n linkwarden
# ... repeat for all 12 PG-dependent services
```

## Restore from Synology (if TrueNAS is down)
1. SSH to Synology NAS (192.168.1.13)
2. Find the replicated dataset: `zfs list | grep postgresql-backup`
3. Mount or copy the backup file to a location accessible from the cluster
4. Follow the restore procedure above

## Estimated Time
- Restore into existing cluster: ~10 minutes (depends on dump size)
- Full rebuild: ~20-30 minutes
