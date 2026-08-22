# Restore PostgreSQL (CNPG)

Last updated: 2026-08-15

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

There is no CNPG-level backup on `pg-cluster` (`spec.backup` is unset, no
barman object store), so these dumps are the whole recovery story — there is no
PITR to fall back on.

### Long-lived migration snapshots — check these for anything older than 14 days
Two uncompressed one-off dumps sit alongside the rolling ones and are **not**
subject to the 14-day retention:

| File | Taken |
|---|---|
| `/mnt/main/postgresql-backup/pre_iscsi_migration.sql` | 3 Mar 2026 |
| `/mnt/main/postgresql-backup/pre-encryption-migration.sql` | 13 Apr 2026 |

They matter because a **silent** data loss is usually older than the rolling
window by the time anyone notices, and the `dump_*` glob used below does not
match them. On 2026-08-15 the `linkwarden` database was found completely empty;
every retained daily dump had already rolled over to schema-only, and the 3 Mar
file was the only surviving copy of the data. Keep both files.

**Diagnostic**: a per-db dump whose byte size is *identical* across many
consecutive days is schema-only — that database is empty, and has been since
before the oldest retained dump. Bisect the two snapshots above to bracket when
the data disappeared.

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

## Restore One Database's Data Into a Live Schema (from a `pg_dumpall` .sql)

Use this when the per-db `.dump` files are useless (e.g. they have all rolled
over to schema-only) and the data only survives inside a full `pg_dumpall`
snapshot, while the live database already has its schema and is being served.
Verified 2026-08-15 recovering `linkwarden` from `pre_iscsi_migration.sql`.

### 1. Cut the database's section out of the dump
`pg_dumpall` output is one file per cluster, delimited by `\connect` lines:

```bash
# find the section boundaries
grep -n 'connect <dbname>' /backup/pre_iscsi_migration.sql        # start
awk 'NR>$START && /^.connect /{print NR; exit}' /backup/pre_iscsi_migration.sql  # end
awk 'NR>=$START && NR<$END' /backup/pre_iscsi_migration.sql > section.sql
```

Keep only the `COPY <table> (...) FROM stdin;` blocks through their terminating
`\.`, plus the `SELECT pg_catalog.setval(...)` lines so new rows get IDs after
the restored ones. Discard all DDL — the live database already has the schema.

### 2. Load it with FK triggers disabled
`pg_dump` emits COPY blocks in **alphabetical** order, which violates existing
foreign keys (e.g. `AccessToken` before `User`). Rather than hand-maintaining a
topological order, disable the triggers for the load:

```sql
BEGIN;
SET session_replication_role = replica;
-- COPY blocks here
SET session_replication_role = DEFAULT;
-- setval statements here
COMMIT;
```

```bash
kubectl exec -i -n dbaas pg-cluster-2 -c postgres -- \
  psql -d <dbname> -v ON_ERROR_STOP=1 < restore.sql
```

`session_replication_role` needs superuser, which the `postgres` user inside the
CNPG pod has.

### 3. Validate the foreign keys the load skipped
Replica mode bypassed FK checking, so verify it explicitly rather than assuming:

```sql
DO $$
DECLARE r RECORD; n BIGINT; bad INT := 0;
BEGIN
  FOR r IN SELECT conname, conrelid::regclass AS src, confrelid::regclass AS tgt,
        (SELECT string_agg(quote_ident(a.attname), ',' ORDER BY x.ord)
           FROM unnest(conkey) WITH ORDINALITY x(att,ord)
           JOIN pg_attribute a ON a.attrelid=conrelid AND a.attnum=x.att) AS scols,
        (SELECT string_agg(quote_ident(a.attname), ',' ORDER BY x.ord)
           FROM unnest(confkey) WITH ORDINALITY x(att,ord)
           JOIN pg_attribute a ON a.attrelid=confrelid AND a.attnum=x.att) AS tcols
      FROM pg_constraint WHERE contype='f' AND connamespace='public'::regnamespace
  LOOP
    EXECUTE format('SELECT count(*) FROM ONLY %s s WHERE (%s) IS NOT NULL AND NOT EXISTS '
                   '(SELECT 1 FROM ONLY %s t WHERE (t.%s)=(s.%s))',
                   r.src, r.scols, r.tgt, r.tcols, r.scols) INTO n;
    IF n > 0 THEN RAISE WARNING 'ORPHANS % on %', n, r.conname; bad := bad+1; END IF;
  END LOOP;
  IF bad = 0 THEN RAISE NOTICE 'FK integrity OK'; ELSE RAISE EXCEPTION '% FKs have orphans', bad; END IF;
END $$;
```

### Notes
- **Schema drift is tolerated automatically.** `COPY` names its columns, so a
  dump predating a new *nullable* column loads fine and leaves it NULL (the
  2026-08-15 restore crossed a `Link.metaDescription` addition this way). A new
  NOT NULL column without a default would need the value supplied.
- **Do not restore `_prisma_migrations`** (or any migration-history table) from
  a dump older than the live schema — it would tell the ORM that migrations
  already applied are still pending, and the next deploy would try to re-run them.

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
