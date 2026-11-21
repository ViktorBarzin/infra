# Garage runbook

Garage is the S3 store behind Cloud Buckets: one pod in namespace `garage`, cluster-only. How it is built: `docs/architecture/garage.md`. Stack: `stacks/garage`. Before any write below (restart, apply, restore), run `presence claim stack:garage --purpose "<what and why>"`.

## Status

```sh
kubectl --context kubernetes-admin@kubernetes -n garage get pods,pvc,cronjob
kubectl --context kubernetes-admin@kubernetes -n garage exec deploy/garage -- /garage status
kubectl --context kubernetes-admin@kubernetes -n garage exec deploy/garage -- /garage layout show
kubectl --context kubernetes-admin@kubernetes -n garage exec deploy/garage -- /garage bucket list
```

`garage status` lists one healthy node. `layout show` shows one role in zone `dc1`. In Prometheus: `up{job="garage"}`, `cluster_healthy{job="garage"}` (1), `garage_local_disk_avail` and `garage_local_disk_total` per `volume`.

`GarageDown` with a ready pod is a scrape failure: `/metrics` needs no token, so check that the `garage` NetworkPolicy still admits `monitoring` on 3903 and that the Service has an endpoint.

The pod starts with `--single-node`. If it logs that it refuses to start because the layout has other nodes, someone changed the layout by hand; `garage layout show` says how.

## Backup check

Each night `nightly-chain` on the Proxmox host runs CronJob `garage-backup`. Check:

- Prometheus: `time() - backup_last_success_timestamp{job="garage-backup"}` under 26 h, `garage_backup_failed_buckets{job="garage-backup"}` 0.
- The last Job's log: `kubectl -n garage logs job/<name> -c sync` (and `-c prepare`).
- The files: `ssh root@192.168.1.127 'ls /srv/nfs/cloud-buckets /srv/nfs/cloud-buckets/current'`.

Run it by hand: `nightly-chain --only garage-backup` on 192.168.1.127, or `kubectl -n garage create job --from=cronjob/garage-backup garage-backup-manual-$(date +%s)`. A second run on the same day only adds files that day's dated directory lacks; it never replaces the previous night's versions there.

First setup, before the first run: the NFS root must exist.

```sh
ssh root@192.168.1.127 'mkdir -p /srv/nfs/cloud-buckets && chown 10001:10001 /srv/nfs/cloud-buckets && chmod 750 /srv/nfs/cloud-buckets'
```

## Restore a whole bucket by hand

Cloud's `cloud bucket restore` copies one key back. For a whole bucket:

1. Pick the state. `current/<bucket>` is the bucket as of the last run. For the state as of an earlier run, start from `current/` and copy each dated directory over it, newest first, down to the date after the run you want. Objects created after that run stay; delete them by hand if they must go.
2. Make a key that may write the bucket, with the admin token from Vault `secret/garage`:

   ```sh
   kubectl -n garage exec deploy/garage -- /garage key create restore-tmp
   kubectl -n garage exec deploy/garage -- /garage bucket allow --read --write --key restore-tmp <bucket>
   ```

3. Run a temporary pod in `garage` from the stack's `rclone_image`, as uid 10001, with PVC `garage-backup-host` mounted read-only at `/backup`, and the key in `RCLONE_CONFIG_GARAGE_*` env vars (endpoint `http://garage.garage.svc.cluster.local:3900`, region `garage`, `force_path_style=true`). Then:

   ```sh
   rclone copy /backup/current/<bucket> garage:<bucket>
   rclone copy /backup/<YYYY-MM-DD>/<bucket> garage:<bucket>   # each older state, newest first
   ```

4. Delete the pod and the key: `/garage key delete --yes restore-tmp`.

If the bucket itself is gone, Cloud recreates it from the Project (its reconciler owns buckets and keys); restore into the new bucket.

## Key rotation

- **Admin token** (also used by Cloud's reconciler): from the main checkout, `cd stacks/garage && ../../scripts/tg apply -replace='random_password.admin_token'`. That writes Vault `secret/garage` and `secret/cloud/garage`. Then force both ExternalSecrets to sync (`kubectl annotate externalsecret -n garage garage-secrets force-sync=$(date +%s) --overwrite`, and Cloud's in namespace `cloud`); Reloader restarts Garage. Requests from the reconciler fail between Garage's restart and its own secret refresh.
- **RPC secret**: `-replace='random_bytes.rpc_secret'`. Only the pod's own CLI uses RPC; a restart is all it needs.
- **Backup key**: `kubectl -n garage exec deploy/garage -- /garage key delete --yes cloud-backup`. The next backup run makes a new one.
- **App keys**: Cloud's (`cloud:<project>/<service>`); rotate them through Cloud.

## Disk full

`GarageDiskFull` fires above 85% on either volume. pvc-autoresizer grows the PVCs at 80% full (`resize.topolvm.io/threshold` 20%) up to `resize.topolvm.io/storage_limit` (data 100Gi, metadata 10Gi), so the alert usually means a volume reached its limit.

1. Check the PVCs: `kubectl -n garage get pvc` and the annotations.
2. Before raising a limit, check the SAS thin pool: `ssh root@192.168.1.127 'lvs sas/data'` (`SASThinPoolFilling` warns at 80%) and `/srv/nfs` free space (the backup needs room for current plus 7 nights of changes).
3. Raise `storage_limit` in `stacks/garage/main.tf`, commit, and let CI apply it.

Which Buckets use the space: `/garage bucket info <bucket>` or the admin API `GetBucketInfo`. Shrinking a Bucket is the Project owner's job; each Bucket has a quota from its Size.

## Storage cost

For B GiB of objects of which C GiB change or are deleted each night:

| Copy | Size |
|---|---|
| Garage data PVC (SAS pool, encrypted) | B, plus metadata about 1% |
| Host `lvm-pvc-snapshot`, 3 days | changed blocks only |
| Host `daily-backup` file copy on sda, 4 weekly generations, hardlinked | B plus a week's changes per generation |
| NFS `/srv/nfs/cloud-buckets` | B for `current/`, plus up to 7 C for the dated directories; up to 8 B if every object changes every night |
| sda, `nfs-mirror` of the above | the same as NFS |
| Synology, `offsite-sync-backup` | the same as NFS, sent as changed files |

So each GiB in Garage costs roughly 4 to 5 GiB across the host, more for Buckets whose objects are rewritten often. Up to 8 copies of a changed object exist on NFS, and again on sda and the Synology.
