# Claude session store

Every Claude Code session on the devvm, for every user, kept in ClickHouse so it can be queried in bulk. Since 2026-11-11 it also keeps the rest of each user's `~/.claude` and `~/.codex` except credentials and caches, so `homelab claude-sessions restore` can write them back after a rebuild ([disposable devvm plan](../plans/2026-11-11-disposable-devvm.md)). Decision record: [ADR-0039](../adr/0039-claude-sessions-are-kept-in-clickhouse.md). Research: [2026-11-07-session-transcript-store.md](../research/2026-11-07-session-transcript-store.md).

```mermaid
flowchart LR
  subgraph devvm["devvm"]
    T["/home/*/.claude and /home/*/.codex<br/>transcripts kept 180 days, history, plans,<br/>tasks, file-history, Codex sessions"]
    I["claude-sessions-ingest.timer<br/>root oneshot, every 15 min<br/>IOReadIOPSMax dm-0 60"]
    Q["homelab claude-sessions sql / schema / restore<br/>admins (sudo group)"]
    T -->|"new bytes only"| I
  end
  subgraph k8s["namespace claude-sessions"]
    ING["Ingress claude-sessions-db.viktorbarzin.me<br/>internal DNS, LAN/VPN allowlist"]
    CH["ClickHouse 26.10.3.7<br/>PVC proxmox-lvm-encrypted-sas"]
    B["CronJob clickhouse-backup 01:40<br/>full Sunday, incremental otherwise"]
  end
  NFS["NFS /srv/nfs/claude-sessions-backup<br/>mirrored to sda and Synology"]
  I -->|"HTTPS, user ingest"| ING
  Q -->|"HTTPS, user reader"| ING
  ING --> CH
  B -->|"native, user default"| CH
  CH --> NFS
```

## Data

| Table | One row per | Notes |
|---|---|---|
| `claude.lines` | transcript line | `raw` is the original JSON line. All other columns are `DEFAULT` expressions over `raw`, computed at insert. Identity columns (`os_user`, `project`, `session_id`, `agent_id`, `file`, `byte_offset`) come from the ingester. |
| `claude.blocks` | message content block | Filled by materialized view `blocks_mv` from `lines`: prompts, replies, thinking, `tool_use` (with `tool_name` and input) and `tool_result` (with `is_error` and output). Text index on `text`. |
| `claude.files` | side file | `tool-results/*.txt` and `subagents/*.meta.json`. `ReplacingMergeTree(mtime)`, so query with `FINAL`. Text index on `content`. |
| `claude.home_files` | file under `~/.claude` or `~/.codex` | Everything that is not a transcript, a credential or a cache, sent whole when it changes: plans, tasks, teams, todos, file-history, settings, workflows, remote/ logs, Codex config and databases. `path` is relative to the home. `encoding` is `text`, `base64` (not UTF-8) or `omitted` (over 32 MiB, no content). `redacted` marks a settings file sent with its secret values replaced. `ReplacingMergeTree(ingested_at)`, so query with `FINAL`. |
| `claude.home_lines` | line of a `.jsonl` home file | `history.jsonl`, Codex rollouts (`.codex/sessions/`) and `session_index.jsonl`, appended like `lines`. `generation` changes when a file is read again from the start; restore uses the newest. |
| `claude.requests` | API request (view) | model and token counts, deduplicated by `requestId`. Sum tokens here: `lines` repeats a message's usage on each of its content-block lines, so summing `lines` inflates tokens about 2.5x. |
| `claude.sessions` | session (view) | cost, prompts, human prompts, subagents, compactions, API requests, tokens (from `requests`), models, start and end. |
| `claude.model_costs` | session and model (view) | cost and tokens per model, from `cost-state`'s per-model `modelUsage`. Use it for spend per model; `arrayJoin(sessions.models)` credits a session's whole cost to every model it touched. |
| `claude.turns` | finished turn (view) | `duration_ms` from Claude Code's `turn_duration` records. |

Details worth knowing before writing queries (`homelab claude-sessions schema` prints them with ten example queries):

- `ts` is the record's own timestamp. Records without one (`mode`, `last-prompt`) take the previous timestamp in the same file (`ts_hint`); `has_own_ts` tells them apart. `cost-state` records use the process start time.
- `sessions.cost_usd` sums the last `cost-state` of each Claude Code process in the session. Resuming a session starts a new process with its own counter, so taking only the maximum would undercount. Claude Code writes `cost-state` occasionally, not after each request, so the figure is final once a session has exited and can lag for a running one. Checked on 2026-11-08: five finished sessions matched Loki's `api_request` cost to the cent.
- A column named `file` can parse as the `file()` table function inside some expressions, which the reader is not allowed to use. Write `lines.file` or a backticked name.
- Full-text search: `hasAnyTokens(text, 'word')` and `hasAllTokens(text, ['a','b'])` use the index and ignore case.

## Ingest

`homelab claude-sessions ingest` (`cli/claude_sessions_ingest.go`), run by `claude-sessions-ingest.timer` from `playbooks/devvm.yml` section 8d:

- Walks `/home/*/.claude` and `/home/*/.codex`. Transcripts (`projects/<slug>/<session>.jsonl`, `<session>/subagents/*.jsonl`, and since 2026-11-11 workflow subagents in `<session>/subagents/workflows/<run>/`) go to `lines`; `tool-results/*.txt` and `*.meta.json` go to `files`; other `.jsonl` files go to `home_lines`; everything else goes whole to `home_files`. It reads directories and stats files; it opens only files whose (inode, size, mtime) changed since the state file (`/var/lib/claude-sessions-ingest/state.json`).
- Never sent (`cli/claude_sessions_home.go`): credentials (`.credentials.json*`, `auth.json`, `*.key`, `*.pem`, any name containing token, secret, credential or oauth), caches and runtime state (`cache/`, `paste-cache/`, `shell-snapshots/`, `session-env/`, `sessions/`, `daemon/`, `backups/` with its copies of `~/.claude.json`, `debug/`, `telemetry/`, `tmp/`, `plugins/cache` and `plugins/marketplaces`, Codex `logs_*.sqlite`, `packages/`, `*-shm`, locks), and downloadable binaries (`remote/ccd-cli/`, `remote/srv/`, `remote/server`). Symlinks are not followed, so `CLAUDE.md` and `AGENTS.md` links stay with the dotfiles.
- Settings files (`settings*.json*`, `*.toml`, `hooks.json`, `*mcp.json`) are sent with secret values replaced by `<redacted>`: values of keys that name a token, key, password or auth, every value under `env` and `headers`, `KEY=value` pairs inside strings, bearer tokens, URL passwords, and long runs mixing upper case, lower case and digits. Checked on 2026-11-11 against all 17 settings files on the box: no token-like string survived.
- Whole home files from many files share one INSERT of up to 8 MB, so a first run makes a few parts, not thousands.
- Reads from the stored byte offset to the end of the last complete line. A partial last line waits for the next run. A smaller file or a new inode restarts the file from 0.
- Sends gzip-compressed JSONEachRow batches of about 8 MB. Each batch carries `insert_deduplication_token = <file>:<first offset>`, so a retried batch is dropped by ClickHouse. The state is saved after every accepted batch.
- Security: runs as root with `ProtectHome=read-only`. Opens files with `O_NOFOLLOW`, ignores symlinks, and skips files not owned by the home directory's owner.
- IO: the unit sets `IOReadIOPSMax=/dev/dm-0 60`, because the devvm IO guard only throttles user slices (`docs/architecture/devvm-io-guard.md`).
- Logs one `claude-sessions-ingest status=... lines=...` line per run to the journal and writes `claude_sessions_ingest_*` to the node_exporter textfile collector.

Credentials come from Vault `secret/claude-sessions` (`clickhouse_password`, `ingest_password`, `reader_password`). The playbook writes `/etc/claude-sessions/ingest.env` (root, 0600) and `reader.env` (root:sudo, 0640). The stack's ExternalSecret reads the same keys.

Size, measured on 2026-11-11 (`system.parts`, bytes on disk): the `claude` database went from 1.60 GB to 2.61 GB with the first run. `home_files` is 75 MB (1,994 files, 213 MB uncompressed) and `home_lines` 12 MB (44,581 lines). The rest, about 0.92 GB in `lines` and `blocks`, is the one-time backlog of 1,211 workflow subagent transcripts that the ingester had been missing. That first run took 22 minutes and sat at the unit's 512 MB `MemoryMax`, mostly page cache; later runs take about 17 seconds. Files that change often (the hooks provisioning rewrites hourly, Codex WALs) are sent again each time they change and merge away; the two 74 MB Codex WALs of one user are over the 32 MiB cap and stored as `omitted`.

## Restore

`homelab claude-sessions restore --user <name> (--to <home> | --tar -) [--session <id>] [--force]` (`cli/claude_sessions_restore.go`) writes the store back into a home directory: `home_files`, `home_lines` (newest generation), `files`, and `lines` reassembled in byte-offset order, with modes and mtimes. Existing files are kept unless `--force`. Redacted settings land as `<name>.from-store`. As root it refuses to write into a directory another user owns; that case uses `--tar - | runuser -u <user> -- tar -x --skip-old-files`. It reads as `reader` with keyset pages of 500 rows and stops at an empty page, so the reader's silent row and byte caps cannot cut a file short. Procedure: [restore-claude-sessions.md](../runbooks/restore-claude-sessions.md).

## Access

| ClickHouse user | Used by | Rights |
|---|---|---|
| `default` | backup CronJob, schema changes | admin |
| `ingest` | devvm timer | `INSERT` on `claude.lines`, `claude.files`, `claude.home_files` and `claude.home_lines` |
| `reader` | `homelab claude-sessions sql/schema/restore` | `SELECT` on `claude.*`, `readonly=2`, 120 s, 2 GB memory, 100,000 rows |
| `netsec_writer` | `stacks/netsec` Vector | `INSERT` on `netsec.*`, hourly quota |
| `netsec_reader` | `homelab netsec sql/schema` (Viktor only) | `SELECT` on `netsec.*`, same limits as `reader` |

The server also hosts the `netsec` database of the network IDS since 2026-11-10 ([network-security-monitoring.md](network-security-monitoring.md)). It is not in the backup.

`blocks_mv` runs with `SQL SECURITY DEFINER` as `default`. Without it, an insert by `ingest` reaches `lines` and then fails in the view.

## Backups and alerts

The `clickhouse-backup` CronJob (`files/backup.sh`) runs `BACKUP DATABASE claude TO Disk('backups', ...)` at 01:40 UTC: a full backup on Sunday, an incremental against the newest full on other days. Incrementals are kept 28 days and fulls 35 days. It pushes `backup_last_success_timestamp{job="claude-sessions-backup"}`. Restore: [restore-claude-sessions.md](../runbooks/restore-claude-sessions.md).

Alerts: `ClaudeSessionsDBDown`, `ClaudeSessionsIngestStale` (no successful ingest for 1 h), `ClaudeSessionsBackupStale` (36 h), `ClaudeSessionsBackupNeverRun`.

## Changing the schema

The image runs `files/schema.sql` from `/docker-entrypoint-initdb.d` only when the data volume is empty. To change a live schema, run the DDL as `default` (for example `kubectl exec` into the pod with `clickhouse-client`), then make the same change in `schema.sql` in the same commit, so a rebuilt volume matches.
