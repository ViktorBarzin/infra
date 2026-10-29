# Restore the Immich database

Last updated: 2026-10-20 (restore of the nightly dump tested into a scratch server)

Immich keeps its metadata (assets, albums, people, faces, CLIP embeddings) in
its own Postgres, Deployment `immich-postgresql` in namespace `immich`, not in
the shared CNPG cluster. Photos and videos live on NFS and are not in this
database. This runbook restores the database from the nightly `pg_dumpall`.

## What is backed up

| Item | Value |
|---|---|
| CronJob | `immich/postgresql-backup`, daily 00:00 UTC (`stacks/immich/main.tf`) |
| Output | `/srv/nfs/immich/postgresql/dump_YYYY_MM_DD_HH_MM.sql.gz` on 192.168.1.127, PVC `immich-postgresql-data-host` in the cluster |
| Format | `pg_dumpall` piped through `gzip -6`, written as `.partial` and renamed when complete. Dumps before 2026-10-20 are plain `.sql` |
| Size (2026-10-20) | 1.44 GB compressed, 3.66 GB uncompressed, database 3.8 GB on disk |
| Retention | 14 days; stale `.partial` files are removed after a day |
| Offsite | Synology `Backup/Viki/nfs/immich/` (offsite-sync step 2) |
| Server image | `ghcr.io/immich-app/postgres:15-vectorchord0.4.3-pgvectors0.2.0` (PG 15.14) |
| Extensions in the dump | `vchord` 0.4.3, `vector` 0.8.1, `cube`, `earthdistance`, `pg_trgm`, `unaccent`, `uuid-ossp`, `pg_buffercache`, `pg_prewarm` |
| Preload the server needs | `shared_preload_libraries = 'vchord.so, vectors.so'` (the image's entrypoint writes it into `/etc/postgresql/postgresql.conf`; the Deployment adds `pg_prewarm` through `postgresql.override.conf`) |

## Pick a dump

A complete dump ends with `-- PostgreSQL database cluster dump complete`.
Check it before restoring, because a run killed partway (the two plain `.sql`
dumps of 10-19 and 10-20 at 00:00) leaves a truncated file:

```bash
zcat dump_2026_10_20_00_10.sql.gz | tail -n 2    # .sql.gz
tail -n 2 dump_2026_10_18_00_00.sql              # older plain .sql
```

Read the files from a pod that mounts `immich-postgresql-data-host` read-only;
never open them for writing.

## Restore into the live server

This path was not run against production; the commands are the ones the
scratch test below ran, pointed at `immich-postgresql`.

1. Claim presence: `presence claim service:immich --purpose "restore immich DB from <dump>"`.
2. If the current database is still readable, take a dump of it first:
   `kubectl -n immich create job immich-pre-restore-$(date +%s) --from=cronjob/postgresql-backup`
   and wait for it to complete.
3. Stop everything that writes to the database. `immich-machine-learning`
   does not connect to Postgres and can stay up.
   ```bash
   kubectl -n immich scale deployment immich-api immich-worker --replicas=0
   ```
   Do not run the restore across 00:00 UTC (the backup CronJob). The
   `immich-search-probe` CronJob (every 5 minutes) fails while the database
   is gone, so `ImmichSmartSearch*` alerts can fire during the window.
4. Drop the old database. This is the destructive step; it needs step 2 or a
   known-good dump.
   ```bash
   kubectl -n immich exec deploy/immich-postgresql -c immich-postgresql -- \
     psql -U immich -d postgres -c "select pg_terminate_backend(pid) from pg_stat_activity where datname='immich' and pid<>pg_backend_pid()" \
     -c "DROP DATABASE immich"
   ```
5. Load the dump from a pod in `immich`, so the data crosses the pod network
   and only status text crosses `kubectl` (long streams through
   `kubectl exec -i` have been cut short before). Set the file name and apply:
   ```yaml
   apiVersion: batch/v1
   kind: Job
   metadata: {name: immich-db-restore, namespace: immich}
   spec:
     backoffLimit: 0
     template:
       spec:
         restartPolicy: Never
         containers:
         - name: restore
           image: ghcr.io/immich-app/postgres:15-vectorchord0.4.3-pgvectors0.2.0@sha256:bcf0e3c6a35df94ee8cd7ad413b5d1a5a0ff18fead0bb241b413f6d664110310
           command: ["bash", "-c"]
           args:
           - |
             f=dump_2026_10_20_00_10.sql.gz
             zcat /backup/$f | psql -X -q -h immich-postgresql -U immich -d postgres 2>&1 | grep -E 'ERROR|FATAL'
             echo "restore finished, zcat rc=${PIPESTATUS[0]} psql rc=${PIPESTATUS[1]}"
           env:
           - name: PGPASSWORD
             valueFrom: {secretKeyRef: {name: immich-secrets, key: db_password}}
           resources: {requests: {cpu: 200m, memory: 64Mi}, limits: {memory: 256Mi}}
           volumeMounts: [{name: backup, mountPath: /backup, readOnly: true}]
         volumes:
         - name: backup
           persistentVolumeClaim: {claimName: immich-postgresql-data-host, readOnly: true}
   ```
   The dump recreates the `immich` database, the `instagram_poster_ro` role
   and every object, including `CREATE EXTENSION vchord` and the `vchordrq`
   indexes. The only expected errors are `role "immich" already exists` and
   `role "postgres" already exists`. Reading the dump straight from the
   read-only NFS mount does not fill the page cache the way writing does, so
   the small memory limit is enough. Expect about 10 minutes.
6. Check the result (expected values from 2026-10-20 in the comments):
   ```bash
   kubectl -n immich exec deploy/immich-postgresql -c immich-postgresql -- psql -U immich -d immich -Atc "
     select count(*) from pg_tables where schemaname not in ('pg_catalog','information_schema');  -- 74
     select extname||' '||extversion from pg_extension order by 1;                                 -- vchord 0.4.3, vector 0.8.1, ...
     select c.relname||' '||am.amname from pg_class c join pg_am am on am.oid=c.relam where c.relname in ('clip_index','face_index');  -- vchordrq
     select count(*) from asset; select count(*) from \"user\"; select count(*) from album;
     select count(*) from (select 1 from smart_search order by embedding <=> (select embedding from smart_search limit 1) limit 10) x;  -- 10"
   ```
7. Restart Postgres so its `postStart` hook and autoprewarm load `clip_index`
   and the `smart_search` / `face_search` TOAST into `shared_buffers`; without
   it the first searches read the index off the HDD:
   `kubectl -n immich rollout restart deployment immich-postgresql`, then
   `kubectl -n immich rollout status deployment immich-postgresql`.
8. Start Immich again with the replica counts from `stacks/immich/main.tf`
   (3 and 1 on 2026-10-20):
   ```bash
   kubectl -n immich scale deployment immich-api --replicas=3
   kubectl -n immich scale deployment immich-worker --replicas=1
   ```
   The scale is transient; the next `immich` apply sets the declared counts.
   Check that `https://immich.viktorbarzin.me` loads and the timeline shows
   recent photos, run `scripts/verify/run immich`, and delete the
   `immich-db-restore` Job.

Assets uploaded after the dump was taken keep their files on NFS but have no
rows in the restored database, so they are missing from the timeline until
they are imported again.

## Restore test (2026-10-20)

The dump `dump_2026_10_20_00_10.sql.gz` (1,442,022,319 bytes, from a manual
run of the CronJob) was loaded into a throwaway Job in `immich`: the same
image, a fresh `initdb -U immich --locale=en_US.utf8` in an emptyDir, the two
preload libraries passed with `-c`, durability off (`fsync=off`,
`wal_level=minimal`), and the dump read from the read-only backup mount.

- The load took 8 min 53 s with one error, `role "immich" already exists`.
- Compared with the live server, read-only: 2 databases, 74 tables, 254
  indexes in `public`, the same 10 extensions at the same versions,
  `clip_index` and `face_index` as `vchordrq`, 6 users, 301 albums, and an
  ANN query over `smart_search` returning 10 rows on both.
- The 15 largest tables matched row for row, 2,485,520 rows in total
  (`smart_search` 179,508, `face_search` 242,905, `asset` 185,278,
  `asset_file` 396,952, `asset_face` 242,905, `asset_exif` 185,269,
  `asset_ocr` 391,514, `album_asset` 157,671, `person` 15,006).

Notes for a repeat: the Job ran `initdb` and `postgres` by hand rather than
the image's entrypoint, because the entrypoint generates
`/etc/postgresql/postgresql.conf` at start and runs a temporary server first.
It also set `dynamic_shared_memory_type=mmap` and
`max_parallel_maintenance_workers=0`, since the container's 64 MB `/dev/shm`
fails parallel index builds, and paused itself while etcd WAL fsync p99 was
above 1 s.
