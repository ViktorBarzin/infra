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

   Side files (`claude.files`) are replaced by path, so re-sending them is harmless; they are absent from the rebuilt state and get sent again. The same holds for `claude.home_files` and `claude.home_lines`: both are `ReplacingMergeTree` keyed by path (and offset), so their files are sent again in full and the duplicates merge away. A re-sent `.jsonl` home file gets a new generation, and restore reads only the newest one.
4. Start the timer again: `sudo systemctl start claude-sessions-ingest.timer`. Lines written after the backup are recovered as long as the local transcripts still hold them (kept 180 days).

## Restore a user's ~/.claude and ~/.codex

After a devvm rebuild, `homelab claude-sessions restore` writes a user's agent
state back from the store: transcripts and subagent transcripts, tool results,
prompt history, plans, tasks, teams, todos, file-history, workflows, Codex
sessions and the settings files. Files that already exist are kept unless
`--force`. Credentials are not in the store; they come from Vault. Admins only
(it uses `/etc/claude-sessions/reader.env`).

```sh
# your own home, as yourself
homelab claude-sessions restore --user wizard --to "$HOME"
# another user's home: build the tar as an admin, extract it as that user, so
# root never writes into a directory the user controls
homelab claude-sessions restore --user emo --tar - | sudo runuser -u emo -- tar -x --skip-old-files -C /home/emo
# one session only, into a scratch HOME, to look at it
homelab claude-sessions restore --user wizard --session <uuid> --to /var/tmp/x
```

On a rebuilt devvm this runs by itself: `t3-provision-users.sh` step 4a calls
`homelab claude-sessions restore --user <name> --rebuild` as root for every
roster user, before step 5 starts their T3 serve. It restores each user once,
records the restored files in the ingest state as already sent, and leaves
`/var/lib/claude-sessions-ingest/restored/<user>`; the ingest leaves a user
alone until that marker exists. Check it after the first provisioning run:

```sh
sudo ls /var/lib/claude-sessions-ingest/restored/     # one file per user
sudo journalctl -u t3-provision-users --since today | grep 'restore --rebuild'
journalctl -u claude-sessions-ingest -n 3 | grep users_waiting_for_restore=0
```

Order matters for a manual restore into a home on a rebuilt box. Run it before
the user first starts claude or codex there, and before the ingest takes the
user on. Otherwise the new box's short `history.jsonl` is kept by
`--skip-old-files`, and once ingested it becomes the newest copy in the store.
`--rebuild` keeps that order for you. To restore a user again on purpose,
remove their marker and the state entries under their home with the timer
stopped.

Only the devvm at 10.0.10.10 ingests. A drill VM restores from the store but
never writes to it (`playbooks/devvm.yml` section 8d).

A settings file whose secrets were redacted at ingest comes back as
`<name>.from-store` (for example `.claude/settings.json.from-store`), never over
the real name; the command lists them. Merge by hand, or let provisioning write
the real file. Files over 32 MiB were stored without content and are counted as
`omitted`.

Tested on 2026-11-11: one of wizard's sessions (1,248 lines and two subagents)
came back byte for byte, and `claude --resume` in a temporary HOME listed it.
A line file with lines missing from the store is written without them and named
in a `WARN ... bytes missing` line.

## netsec rollups

Since 2026-11-11 each backup also holds the `netsec` hourly rollups (every
`netsec` table named `*_hourly`), never the raw `netsec` tables. Restore one
beside the live table to check it, or after a lost volume into the empty table
that `schema.sql` created (stop `netsec-vector` first, or the materialized
views add rows during the restore):

```sh
kubectl -n claude-sessions exec -it deploy/clickhouse -- bash -c \
  'clickhouse-client --password "$CLICKHOUSE_PASSWORD" -q "RESTORE TABLE netsec.flows_hourly AS netsec.flows_hourly_restore FROM Disk('"'"'backups'"'"', '"'"'<name>'"'"')"'
# after a lost volume, into the live table instead:
#   RESTORE TABLE netsec.flows_hourly FROM Disk('backups', '<name>') SETTINGS allow_non_empty_tables = true
```

Tested on 2026-11-11: a restored `flows_hourly` summed to the same flow count
as the live table for every complete hour. The raw tables are lost with the
volume; the views fill the rollups again from the first new insert.

## Lost volume

If the PVC is gone, Terraform recreates it and the image's initdb creates an empty schema from `files/schema.sql`. Then run step 2 above (drop the empty database first).

## Before upgrading ClickHouse

Run the CronJob once by hand and check the new backup exists, as for rybbit (`docs/runbooks/restore-clickhouse.md`). Parts written by a newer release cannot be read by an older one.

```sh
kubectl -n claude-sessions create job --from=cronjob/clickhouse-backup backup-manual-$(date +%s)
```
