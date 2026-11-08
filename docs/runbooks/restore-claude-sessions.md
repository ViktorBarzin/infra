# Restore the Claude session store

The `claude-sessions` ClickHouse (ADR-0039) is backed up nightly by the `clickhouse-backup` CronJob to `/srv/nfs/claude-sessions-backup/` on the PVE host, which the pod and the job mount at `/backups`. Each backup is a directory:

- `full-<yyyymmdd-hhmmss>`: complete copy, taken on Sundays (or when no full exists).
- `incr-<yyyymmdd-hhmmss>`: changes since the newest full at the time. ClickHouse reads its base automatically on restore, so the base full must still exist.

## Check what you have

```sh
kubectl -n claude-sessions exec deploy/clickhouse -- ls -1 /backups
```

Pick the newest directory. An incremental is enough on its own; its base is found through the `.backup` metadata.

## Restore beside the live data (safe check)

```sh
kubectl -n claude-sessions exec -it deploy/clickhouse -- bash -c \
  'clickhouse-client --password "$CLICKHOUSE_PASSWORD" -q "RESTORE DATABASE claude AS claude_restore FROM Disk('"'"'backups'"'"', '"'"'<name>'"'"')"'
kubectl -n claude-sessions exec -it deploy/clickhouse -- bash -c \
  'clickhouse-client --password "$CLICKHOUSE_PASSWORD" -q "SELECT (SELECT count() FROM claude.lines), (SELECT count() FROM claude_restore.lines)"'
kubectl -n claude-sessions exec -it deploy/clickhouse -- bash -c \
  'clickhouse-client --password "$CLICKHOUSE_PASSWORD" -q "DROP DATABASE claude_restore SYNC"'
```

Tested on 2026-11-08 against a full plus an incremental: the restored counts matched the live tables, including a row written between the two backups.

## Replace the live database

1. Stop ingest so nothing writes during the swap: `sudo systemctl stop claude-sessions-ingest.timer` on the devvm.
2. `DROP DATABASE claude SYNC`, then `RESTORE DATABASE claude FROM Disk('backups', '<name>')` as above.
3. The ingester's state file now points past lines the restored database does not have. Rebuild it from what the database holds, so the next run sends exactly the missing lines. Do NOT simply delete the state file: a re-send from offset 0 splits batches differently from the original 15-minute runs, the dedup tokens do not match, and every line would be stored twice.

   ```sh
   # on the devvm, as root
   kubectl -n claude-sessions exec deploy/clickhouse -- bash -c \
     'clickhouse-client --password "$CLICKHOUSE_PASSWORD" -q "SELECT file, max(byte_offset + length(raw) + 1) AS next FROM claude.lines GROUP BY file FORMAT JSONEachRow"' \
     > /root/claude-offsets.json
   python3 -I - <<'PY'
   import json, os
   files = {}
   for line in open('/root/claude-offsets.json'):
       r = json.loads(line)
       try:
           st = os.stat(r['file'], follow_symlinks=False)
       except FileNotFoundError:
           continue
       # size -1 marks the file part-done, so the next run reads on from "offset"
       files[r['file']] = {"inode": st.st_ino, "size": -1, "mtime_ns": st.st_mtime_ns, "offset": int(r['next'])}
   json.dump({"files": files}, open('/var/lib/claude-sessions-ingest/state.json', 'w'))
   PY
   ```

   Side files (`claude.files`) are replaced by path, so re-sending them is harmless; they are absent from the rebuilt state and get sent again.
4. Start the timer again: `sudo systemctl start claude-sessions-ingest.timer`. Lines written after the backup are recovered as long as the local transcripts still hold them (kept 180 days).

## Lost volume

If the PVC is gone, Terraform recreates it and the image's initdb creates an empty schema from `files/schema.sql`. Then run step 2 above (drop the empty database first).

## Before upgrading ClickHouse

Run the CronJob once by hand and check the new backup exists, as for rybbit (`docs/runbooks/restore-clickhouse.md`). Parts written by a newer release cannot be read by an older one.

```sh
kubectl -n claude-sessions create job --from=cronjob/clickhouse-backup backup-manual-$(date +%s)
```
