# Restore PostgreSQL (CNPG)

Last updated: 2026-04-06

## Prerequisites
- `kubectl` access to the cluster
- CNPG operator running in the cluster
- Backup dump available on NFS at `/mnt/main/postgresql-backup/`
- PostgreSQL superuser password (from `pg-cluster-superuser` secret in `dbaas` namespace)

## Backup Location
- NFS: `/mnt/main/postgresql-backup/dump_YYYY_MM_DD_HH_MM.sql.gz`
- Mirrored to sda: `/mnt/backup/nfs-mirror/postgresql-backup/` (PVE host 192.168.1.127)
- Replicated to Synology NAS: `Synology/Backup/Viki/pve-backup/nfs-mirror/postgresql-backup/`
- Retention: 14 days (on NFS), latest only (on sda), unlimited (on Synology)

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

# Restore (decompress and pipe to psql — this will overwrite existing data)
PGPASSWORD=$(kubectl get secret pg-cluster-superuser -n dbaas -o jsonpath='{.data.password}' | base64 -d) \
  zcat /path/to/dump_YYYY_MM_DD_HH_MM.sql.gz | psql -h 127.0.0.1 -p 5433 -U postgres
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
  --overrides='{"spec":{"volumes":[{"name":"backup","persistentVolumeClaim":{"claimName":"dbaas-postgresql-backup"}}],"containers":[{"name":"pg-restore","image":"postgres:16.4-bullseye","env":[{"name":"PGPASSWORD","value":"'$PGPASSWORD'"}],"volumeMounts":[{"name":"backup","mountPath":"/backup"}],"command":["/bin/sh","-c","zcat /backup/dump_YYYY_MM_DD_HH_MM.sql.gz | psql -h pg-cluster-rw.dbaas -U postgres"]}]}}' \
  -n dbaas
```

### 4. Verify restoration
```bash
# Check databases exist
PGPASSWORD=$PGPASSWORD psql -h 127.0.0.1 -p 5433 -U postgres -c "\l"

# Check table counts for critical databases
for db in health linkwarden affine woodpecker claude_memory; do
  echo "=== $db ==="
  PGPASSWORD=$PGPASSWORD psql -h 127.0.0.1 -p 5433 -U postgres -d $db -c \
    "SELECT schemaname, tablename, n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC LIMIT 5;"
done
```

### 5. Restart dependent services
After restore, restart services that connect to PostgreSQL to pick up fresh connections:
```bash
kubectl rollout restart deployment -n health
kubectl rollout restart deployment -n linkwarden
# ... repeat for all PG-dependent services (excluding trading — disabled)
```

## Restore Single Database (from per-db backup)

Per-database backups use `pg_dump -Fc` (custom format) and are stored at `/mnt/main/postgresql-backup/per-db/<dbname>/`.

### 1. List available per-db backups
```bash
ls -lt /mnt/main/postgresql-backup/per-db/<dbname>/

# Or via a pod:
kubectl exec -n dbaas pg-cluster-1 -c postgres -- ls -lt /backup/per-db/<dbname>/ 2>/dev/null || \
  echo "Mount a backup pod — see Option A below"
```

### 2. Restore a single database
```bash
# Port-forward to the CNPG primary
kubectl port-forward svc/pg-cluster-rw -n dbaas 5433:5432 &

# Restore single database (drops and recreates objects in that DB only)
PGPASSWORD=$(kubectl get secret pg-cluster-superuser -n dbaas -o jsonpath='{.data.password}' | base64 -d) \
  pg_restore -h 127.0.0.1 -p 5433 -U postgres -d <dbname> --clean --if-exists \
  /path/to/per-db/<dbname>/dump_YYYY_MM_DD_HH_MM.dump
```

### 3. Verify
```bash
PGPASSWORD=$PGPASSWORD psql -h 127.0.0.1 -p 5433 -U postgres -d <dbname> -c \
  "SELECT schemaname, tablename, n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC LIMIT 10;"
```

### 4. Restart the affected service only
```bash
kubectl rollout restart deployment -n <namespace>
```

**Advantages over full restore**: Only the target database is affected. All other databases continue running with their current data.

## Alternative: Restore from sda Backup

If the Proxmox host NFS mount is unavailable but the PVE host itself is accessible:

```bash
# 1. SSH to PVE host
ssh root@192.168.1.127

# 2. Find the latest backup
ls -lt /mnt/backup/nfs-mirror/postgresql-backup/

# 3. Mount sda backup on a pod
PGPASSWORD=$(kubectl get secret pg-cluster-superuser -n dbaas -o jsonpath='{.data.password}' | base64 -d)

kubectl run pg-restore --rm -it --image=postgres:16.4-bullseye \
  --overrides='{"spec":{"volumes":[{"name":"backup","hostPath":{"path":"/mnt/backup/nfs-mirror/postgresql-backup"}}],"containers":[{"name":"pg-restore","image":"postgres:16.4-bullseye","env":[{"name":"PGPASSWORD","value":"'$PGPASSWORD'"}],"volumeMounts":[{"name":"backup","mountPath":"/backup"}],"command":["/bin/sh","-c","zcat /backup/dump_YYYY_MM_DD_HH_MM.sql.gz | psql -h pg-cluster-rw.dbaas -U postgres"]}],"nodeName":"k8s-master"}}' \
  -n dbaas
```

## Alternative: Restore from Synology (if PVE host is down)

If the PVE host itself is unavailable:

```bash
# 1. SSH to Synology NAS
ssh Administrator@192.168.1.13

# 2. Navigate to backup directory
cd /volume1/Backup/Viki/nfs/postgresql-backup/

# 3. Copy dump to a temporary location accessible from cluster
# (e.g., via rsync to a surviving node, or restore PVE host first)
```

## Estimated Time
- Restore into existing cluster: ~10 minutes (depends on dump size)
- Full rebuild: ~20-30 minutes
