# Restore ClickHouse (rybbit)

Last updated: 2026-10-10 (backup CronJob added)

Applies to the single-replica `clickhouse` Deployment in the `rybbit`
namespace, the event store for Rybbit analytics.

## Backup locations

| Location | Written by | Retention |
|---|---|---|
| `/srv/nfs/clickhouse-backup/<yyyymmdd-hhmm>/` on the PVE host, PVC `rybbit-clickhouse-backup-host` in the cluster | CronJob `rybbit/clickhouse-backup`, daily 01:10 UTC | 14 days |
| `/mnt/backup/clickhouse-backup/` on the PVE host | `nfs-mirror`, daily 02:00 | mirror |
| Synology `Backup/Viki/pve-backup/clickhouse-backup/` | `offsite-sync-backup` | offsite |

Each run directory holds, per user table:

- `<db>.<table>.sql`: the `SHOW CREATE TABLE` statement
- `<db>.<table>.native.gz`: the rows, `SELECT * ... FORMAT Native`, gzipped

plus `<db>.database.sql`, `VERSION` (server version at dump time), `counts.tsv`
(rows per table at dump time), `tables.tsv` and `SHA256SUMS`.

The job restores every dump into `clickhouse-local` from the same image before
it writes the directory, and pushes `backup_last_success_timestamp{job="clickhouse-backup"}`
only after that check passes. A directory that exists under its final name has
been read back once. Alerts: `ClickHouseBackupStale` (36h), `ClickHouseBackupNeverRun`,
and the generic `BackupCronJobFailed`.

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
zcat "$D/clickhouse.events.native.gz" | ch -q "INSERT INTO clickhouse.events FORMAT Native"
ch -q "SELECT count() FROM clickhouse.events"                        # compare with counts.tsv
```

Drop `clickhouse.events_broken` once Rybbit shows the restored data.

## Restore everything into an empty server

For a wiped or recreated PVC: let the Deployment start with an empty data
directory, then, in the same throwaway pod, create each database from
`<db>.database.sql` (skip `default`, which already exists) and repeat the
two table commands above for every line of `tables.tsv`. Tables whose third
`tables.tsv` column is `0` are views or other data-less engines and need only
the `.sql` file; create them after the tables they read from.
