# Restart prometheus-server without losing the head block

prometheus-server keeps its WAL on a tmpfs (`emptyDir` with `medium: Memory`, 2Gi, mounted at `/data/wal`) to spare the SSD. Blocks and `chunks_head` are on the PVC `prometheus-data-proxmox`. When the pod is replaced, the new pod gets an empty tmpfs, the m-mapped head chunks cannot be matched to series without the WAL, and the head block is gone: everything since the last head compaction, between 1 and 3 hours of samples. A restart through the rails on 2026-10-14 lost 116 minutes.

Every chart bump replaces the pod, because the pod template carries the `helm.sh/chart` label, and so does any change to the images in `prometheus_chart_values.tpl`. Renovate lands those through the rails, which accept the gap. This runbook is for a restart you control, or for recovering the head after one you did not.

## Planned restart

The idea: write the head out as an ordinary block with the snapshot API, put that block in the data directory, then restart. Measured on 2026-10-15: the snapshot took 19 s and produced a 46 MB block for 2 h of head (145,000 series, 9.1 M samples).

1. Optional: wait for a head compaction, so the head block is small and sits inside one 2 h window. Compaction runs once the head spans more than 3 h, so `prometheus_tsdb_head_min_time_seconds` jumps by 2 h at that moment. Read it live, since the scraped value lags by a scrape interval:

   ```sh
   P=$(kubectl -n monitoring get pod -l app.kubernetes.io/component=server -o name)
   kubectl -n monitoring exec $P -c prometheus-backup -- sh -c \
     'wget -qO- http://localhost:9090/metrics | grep ^prometheus_tsdb_head_min_time_seconds'
   ```

2. Snapshot including the head (the admin API is enabled with `web.enable-admin-api`):

   ```sh
   kubectl -n monitoring exec $P -c prometheus-backup -- \
     wget -qO- --post-data='' 'http://localhost:9090/api/v1/admin/tsdb/snapshot?skip_head=false'
   ```

   The snapshot directory `/data/snapshots/<name>/` holds hard links to every persisted block plus one new block for the head. The head block is the one whose ULID is not already a directory in `/data`.

3. Move that block into the data directory. A rename inside the PVC is atomic, so Prometheus never sees a partial block:

   ```sh
   kubectl -n monitoring exec $P -c prometheus-server -- \
     mv /data/snapshots/<name>/<ULID> /data/<ULID>
   ```

   The running Prometheus loads it within a minute (it reloads blocks every minute) and truncates its head to the block's end. Queries over that range still return data, from the block.

4. Apply the change straight away (`scripts/tg apply` from the main checkout). The gap is now the time from the snapshot to the first scrape of the new pod. Opening the TSDB took 92 s on 2026-10-15 (about 35 blocks, 80 GB).

5. Remove the rest of the snapshot directory with `rm -r /data/snapshots/<name>`. It holds only hard links, so this frees no space and touches no live block.

Because the block is already in `/data` when the new pod starts, alert `for:` state is restored from the `ALERTS_FOR_STATE` series it contains.

Land the commit and apply it in the same sitting. On 2026-10-15 the commit was pushed with `[ci skip]` an hour before the planned apply, another session pushed an unrelated monitoring change without `[ci skip]` a few minutes later, and CI applied both before the snapshot was taken.

## Recovering after an unplanned restart

The old pod keeps its tmpfs until the pod object is gone. The `prometheus-backup` sidecar ignores SIGTERM, so a terminating pod stays for the full `terminationGracePeriodSeconds` (300 s), and the WAL can be copied in that window even after the Prometheus container has exited. On 2026-10-15 this brought back 2 h 3 min of head, and the data gap was 6 min 55 s instead of 2 h 10 min.

1. Copy the tmpfs and `chunks_head` off the node before the deadline in `metadata.deletionTimestamp`. `kubectl exec` into the Prometheus container stops working once it exits, so use a node debug pod. The pod's volumes are under `/host/var/lib/kubelet/pods/<pod-uid>/volumes/`: the tmpfs is `kubernetes.io~empty-dir/prometheus-wal-tmpfs`, and the NFS backup volume `kubernetes.io~csi/monitoring-prometheus-backup-host/mount` (`/srv/nfs/prometheus-backup` on the PVE host) is a durable place to put the copy.

   ```sh
   U=$(kubectl -n monitoring get pod <old-pod> -o jsonpath='{.metadata.uid}')
   kubectl debug node/<node> -n monitoring --profile=sysadmin --image=docker.io/library/busybox:latest -- sh -c "set -e
     V=/host/var/lib/kubelet/pods/$U/volumes
     B=\$V/kubernetes.io~csi/monitoring-prometheus-backup-host/mount/salvage-<date>
     M=\$(ls -d \$V/kubernetes.io~csi/pvc-*/mount)
     mkdir -p \$B
     cp -a \$V/kubernetes.io~empty-dir/prometheus-wal-tmpfs \$B/wal
     cp -a \$M/chunks_head \$B/chunks_head"
   ```

2. Replay it in a throwaway Prometheus of the same version: a pod in `monitoring` that mounts `monitoring-prometheus-backup-host` read-only, copies `wal` and `chunks_head` into an `emptyDir`, and runs `prometheus --storage.tsdb.path=<that dir> --web.enable-admin-api` with an empty config (`global: {}`). Kyverno wants the fully qualified image (`quay.io/prometheus/prometheus:<version>`) and resources; 3Gi was enough for 165,000 series.

3. The replayed head can start earlier than the last persisted block, because `chunks_head` keeps chunks older than the last truncation. Let the throwaway instance compact once on its own (a minute after start it cuts 2 h blocks while the head spans more than 3 h), until its `prometheus_tsdb_head_min_time_seconds` equals the end of the newest block in the live TSDB. Then take a snapshot with `skip_head=false`. Its head block now starts exactly where the live blocks end.

4. Stream that block into the PVC and rename it into place. If the old pod is still terminating, its sidecar mounts `/data` and the new Prometheus will load the block at startup. Otherwise use the new pod's sidecar, and the block loads within a minute:

   ```sh
   kubectl -n monitoring exec <recover-pod> -- tar cf - -C /tsdb/data/snapshots/<name> <ULID> \
     | kubectl -n monitoring exec -i <prometheus-pod> -c prometheus-backup -- sh -c \
       'set -e; mkdir -p /data/incoming; tar xf - -C /data/incoming; mv /data/incoming/<ULID> /data/<ULID>; rmdir /data/incoming'
   ```

5. Check: `count(up)` over the old head's range has no hole, and `prometheus_tsdb_blocks_loaded` went up by one. Delete the throwaway pod.

## Why not move the WAL to disk

The WAL went to tmpfs to cut writes to the shared SSD (`SSDHighWriteRate`). A persistent WAL would make every restart lossless with no procedure, at the cost of that write volume. That decision stands for now, and this runbook is the trade.
