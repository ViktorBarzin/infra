# Restore Dolt (beads-server)

Last updated: 2026-10-10 (backup CronJob added)

Applies to the single-replica `dolt` Deployment in the `beads-server`
namespace. It holds the `code` database (beads issues, read and written by
`bd` and BeadBoard) and the `beads` database (`presence_claims`, the presence
CLI's lock table).

## Backup locations

| Location | Written by | Retention |
|---|---|---|
| `/srv/nfs/dolt-backup/<yyyymmdd-hhmm>/` on the PVE host, PVC `beads-dolt-backup-host` in the cluster | CronJob `beads-server/dolt-backup`, daily 01:25 UTC | 14 days |
| `/mnt/backup/dolt-backup/` on the PVE host | `nfs-mirror`, daily 02:00 | mirror |
| Synology `Backup/Viki/pve-backup/dolt-backup/` | `offsite-sync-backup` | offsite |

Each run directory holds `<db>.sql.gz` per database, plus `VERSION`
(`dolt_version()` at dump time), `counts.tsv` (rows per table), `views.tsv`,
`databases` and `SHA256SUMS`.

## What the backup contains

- Current rows of every table in every user database, including changes not yet
  committed to Dolt (`beads.presence_claims` is never committed).
- View definitions, appended from `dolt_schemas` (mysqldump only writes
  placeholder views against Dolt).
- Not Dolt commit history. A restore produces the current state as one new
  commit. The tarball taken before each Dolt version bump is the copy with
  history.
- Not users and grants. Those come from the `dolt-init` ConfigMap
  (`01-create-beads-user.sql`).

The job's dump container is `mysql:8.4.8` (`dolt dump` has no remote mode in
2.4.2). Its verify container runs the same Dolt image as the server: it
restores the dump into a scratch Dolt directory, checks every table and view
comes back, and only then writes the run directory and pushes
`backup_last_success_timestamp{job="dolt-backup"}`. Alerts: `DoltBackupStale`
(36h), `DoltBackupNeverRun`, and the generic `BackupCronJobFailed`.

## Run a backup now

```bash
kubectl -n beads-server create job --from=cronjob/dolt-backup dolt-backup-manual-$(date +%s)
kubectl -n beads-server logs -f job/<name> -c dump
kubectl -n beads-server logs -f job/<name> -c verify
```

## Restore into the live server

The dump starts each table with `DROP TABLE IF EXISTS`, so it replaces the
tables it contains. Stop writers first if the restore must not race them
(BeadBoard: scale `beadboard` to 0; the dispatcher CronJobs are already off by
default).

```bash
kubectl -n beads-server run dolt-restore --rm -it --restart=Never \
  --image=mysql:8.4.8 \
  --overrides='{"spec":{"volumes":[{"name":"b","persistentVolumeClaim":{"claimName":"beads-dolt-backup-host","readOnly":true}}],"containers":[{"name":"dolt-restore","image":"mysql:8.4.8","command":["bash"],"stdin":true,"tty":true,"volumeMounts":[{"name":"b","mountPath":"/backup","readOnly":true}]}]}}'

# inside the pod
ls /backup                                   # pick a run directory
D=/backup/<yyyymmdd-hhmm>
H="-h dolt.beads-server.svc.cluster.local -P 3306 -u root"
zcat "$D/code.sql.gz" | mysql $H
mysql $H code -e "CALL dolt_commit('-Am', 'restore from backup <yyyymmdd-hhmm>')"
mysql $H code -e "SELECT COUNT(*) FROM issues"   # compare with counts.tsv
```

Repeat for `beads.sql.gz` only if the presence table is damaged; its rows are
short-lived claims.

## Rehearse a restore without touching the server

The verify container already does this on every run. To repeat it by hand,
start a pod on `dolthub/dolt-sql-server:2.4.2` with the backup PVC mounted,
then:

```bash
export HOME=/tmp; mkdir /tmp/r && cd /tmp/r
dolt config --global --add user.name restore; dolt config --global --add user.email restore@local
zcat /backup/<yyyymmdd-hhmm>/code.sql.gz | dolt sql
dolt sql -q "SELECT COUNT(*) FROM code.issues; SELECT COUNT(*) FROM code.ready_issues"
```
