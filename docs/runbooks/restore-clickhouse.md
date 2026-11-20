# Restore ClickHouse (rybbit)

Last updated: 2026-11-20 (session replay dumped by day into a shared chunk store, infra#215)

Applies to the single-replica `clickhouse` Deployment in the `rybbit`
namespace, the event store for Rybbit analytics.

## Backup locations

| Location | Written by | Retention |
|---|---|---|
| `/srv/nfs/clickhouse-backup/<yyyymmdd-hhmm>/` on the PVE host, PVC `rybbit-clickhouse-backup-host` in the cluster | CronJob `rybbit/clickhouse-backup`, daily 01:10 UTC | 14 days |
| `/mnt/backup/clickhouse-backup/` on the PVE host | `nfs-mirror`, nightly chain (after the dump) | mirror |
| Synology `Backup/Viki/pve-backup/clickhouse-backup/` | `offsite-sync-backup` | offsite |

Each run directory holds, per user table:

- `<db>.<table>.sql`: the `SHOW CREATE TABLE` statement
- `<db>.<table>.native.zst`: the rows, `SELECT * ... FORMAT Native`, zstd-compressed
  by `clickhouse-client` (`INTO OUTFILE ... COMPRESSION 'zstd'`). Runs before
  2026-11-20 hold `.native.gz` (gzip) instead.

plus `<db>.database.sql`, `VERSION` (server version at dump time), `counts.tsv`
(rows per table at dump time), `tables.tsv`, `chunks.tsv` and `SHA256SUMS`.

**Chunked tables** (`clickhouse.session_replay_events`, almost all of the
bytes) have no `.native.zst` in the run directory. They are dumped one UTC day
at a time into a store shared by every run (infra#215):

```
/backup/chunks/<db>.<table>/<yyyy-mm-dd>-<rows>-<fp>.native.zst   # Native, zstd
/backup/chunks/<db>.<table>/<yyyy-mm-dd>-<rows>-<fp>.native.zst.sha256
```

`fp` is `sum(cityHash64(session_id, sequence_number, timestamp))` over that day.
A day with the same fingerprint as a stored chunk is not dumped again, so a
night writes only the days that changed (normally today and yesterday). The
run's `chunks.tsv` lists the chunks that make up that run: `db`, `table`,
`day`, `rows`, chunk path relative to `/backup`, `sha256`. Restoring a run means
loading every chunk it lists. The job deletes a chunk once no retained run
directory lists it, and only if the chunk is older than 3 h.

The job restores every dump into `clickhouse-local` from the same image before
it writes the directory. That covers every table dumped whole, plus the chunks
it wrote that night. A reused chunk was read back on the night it was written,
and on Sundays the job checks each reused chunk against its `.sha256`. A chunk
that fails is renamed `*.corrupt-<run>` and dumped again from the live table.
`backup_last_success_timestamp{job="clickhouse-backup"}` is pushed only after the
check passes, along with `backup_chunks_dumped`, `backup_chunks_reused` and
`backup_chunk_store_bytes`. A directory that exists under its final name has
been read back. Alerts: `ClickHouseBackupStale` (36h), `ClickHouseBackupNeverRun`,
and the generic `BackupCronJobFailed`.

The check runs in the Job's 2Gi container (1Gi failed about half the runs on a 1.9 GB dump, infra#208). It gives `clickhouse-local` a
one-line config with `memory_worker_use_cgroup=0`, so the cap (0.9 × the
limit) counts ClickHouse's own allocations and not the page cache of the
dump it reads. It also inserts on one thread in 32 MiB blocks. Without
both, a dump of a few GB fails with `MEMORY_LIMIT_EXCEEDED` while real
usage stays low (infra#205). Reuse those flags when you restore a large
table with `clickhouse-local` by hand.

## Version rule

Restore with the same ClickHouse release that wrote the dump (`VERSION` in the
run directory). Native files read forward across releases, but parts written by
26.x cannot be read by 25.x, so a rollback restore needs the matching older image.

## Run a backup now

```bash
kubectl -n rybbit create job --from=cronjob/clickhouse-backup clickhouse-backup-manual-$(date +%s)
kubectl -n rybbit logs -f job/<name>
```

## Restore one table into the live server

Run from a throwaway pod on the server's image that mounts the backup PVC:

```bash
kubectl -n rybbit run ch-restore --rm -it --restart=Never \
  --image=clickhouse/clickhouse-server:26.9.14.10 \
  --overrides='{"spec":{"volumes":[{"name":"b","persistentVolumeClaim":{"claimName":"rybbit-clickhouse-backup-host","readOnly":true}}],"containers":[{"name":"ch-restore","image":"clickhouse/clickhouse-server:26.9.14.10","command":["bash"],"stdin":true,"tty":true,"volumeMounts":[{"name":"b","mountPath":"/backup","readOnly":true}],"env":[{"name":"CLICKHOUSE_PASSWORD","valueFrom":{"secretKeyRef":{"name":"rybbit-secrets","key":"clickhouse_password"}}}]}]}}'

# inside the pod
ls /backup                                   # pick a run directory
D=/backup/<yyyymmdd-hhmm>
ch() { clickhouse-client --host clickhouse.rybbit.svc.cluster.local --port 9000 --user default --password "$CLICKHOUSE_PASSWORD" "$@"; }
ch -q "RENAME TABLE clickhouse.events TO clickhouse.events_broken"   # keep the old copy until verified
ch --queries-file "$D/clickhouse.events.sql"
ch -q "INSERT INTO clickhouse.events FROM INFILE '$D/clickhouse.events.native.zst' COMPRESSION 'zstd' FORMAT Native"
# a run from before 2026-11-20 (gzip):
# zcat "$D/clickhouse.events.native.gz" | ch -q "INSERT INTO clickhouse.events FORMAT Native"
ch -q "SELECT count() FROM clickhouse.events"                        # compare with counts.tsv
```

For a chunked table, load every chunk the run lists, not a single file:

```bash
ch -q "RENAME TABLE clickhouse.session_replay_events TO clickhouse.session_replay_events_broken"
ch --queries-file "$D/clickhouse.session_replay_events.sql"
awk -F'\t' '$1=="clickhouse" && $2=="session_replay_events" {print $6"  /backup/"$5}' "$D/chunks.tsv" | sha256sum -c -   # chunks intact
awk -F'\t' '$1=="clickhouse" && $2=="session_replay_events" {print $5}' "$D/chunks.tsv" | while read -r c; do
  ch --min_insert_block_size_bytes=16777216 -q "INSERT INTO clickhouse.session_replay_events FROM INFILE '/backup/$c' COMPRESSION 'zstd' FORMAT Native" < /dev/null
done
ch -q "SELECT count() FROM clickhouse.session_replay_events"           # compare with counts.tsv
```

Keep inserts at 16 MiB blocks or smaller against the live server: 128 MiB
blocks ran it out of memory (infra#206).

Drop `clickhouse.events_broken` once Rybbit shows the restored data.

## Restore everything into an empty server

For a wiped or recreated PVC: let the Deployment start with an empty data
directory, then, in the same throwaway pod, create each database from
`<db>.database.sql` (skip `default`, which already exists) and repeat the
table commands above for every line of `tables.tsv`, using the chunk loop for
tables listed in `chunks.tsv`. Tables whose third `tables.tsv` column is `0`
are views or other data-less engines and need only the `.sql` file; create
them after the tables they read from.
