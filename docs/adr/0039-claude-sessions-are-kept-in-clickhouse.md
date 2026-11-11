# ADR-0039: Every Claude session is kept in a ClickHouse store

- Status: accepted
- Date: 2026-11-08
- Related: ADR-0025 (amended), `docs/research/2026-11-07-session-transcript-store.md`, `docs/architecture/claude-session-store.md`, `stacks/claude-sessions/`, `cli/cmd_claude_sessions.go`, `cli/claude_sessions_ingest.go`

## Context

Viktor wants every Claude Code session on the devvm kept and queryable in bulk, to see how work with agents improves over time: cost, tool failures, slow turns, friction, and what was worked on.

Until 2026-11-07 Claude Code deleted transcripts older than 30 days (`cleanupPeriodDays` default), so the on-disk history that ADR-0025 relied on was a rolling 30 days. Loki holds the OpenTelemetry events for 30 days and does not hold transcripts. `homelab claude-usage` reads transcripts from disk, which is slow at this size and competes with etcd for the devvm disk.

The research note compared ClickHouse, Postgres on CNPG, DuckDB over an archive, Loki, OpenSearch, Meilisearch, Typesense, Langfuse and Phoenix.

## Decision

1. **A dedicated single-node ClickHouse** (`stacks/claude-sessions`) holds every transcript line of every devvm user's Claude Code sessions, including subagent transcripts, large tool outputs (`tool-results/`) and subagent metadata. It runs the same image pin as `stacks/rybbit`, on `proxmox-lvm-encrypted-sas`.
2. **The database plus its backups is the archive.** Each line is stored verbatim (`raw`); every other column is computed by ClickHouse from it, so a change in Claude Code's record format is fixed in SQL. Backups are native `BACKUP` to NFS, a full on Sunday and incrementals on other days.
3. **A oneshot root timer ingests**, not a resident daemon and not a hook. `claude-sessions-ingest.timer` runs `homelab claude-sessions ingest` every 15 minutes. It stats each transcript file and reads only the bytes appended since its stored offset. Hooks were considered and not chosen because they miss subagent files, tool-result files and sessions that were killed.
4. **Admins query it** through `homelab claude-sessions sql` and `schema`. The reader account is read-only with time, memory and result limits, so an agent-written query cannot take the server down.
5. **Local transcripts are kept 180 days** (`cleanupPeriodDays: 180`) once the store is proven, so the devvm disk does not fill.
6. **No redaction.** Transcripts contain tool output, which can include secrets. The store is on an encrypted volume, reachable only from the LAN and VPN, and readable only by admins.

## What this changes in ADR-0025

ADR-0025 chose not to add a transcript-tailing daemon, for two reasons: a resident process, and read access across every user's home directory. This ADR keeps the first boundary (the ingester is a oneshot timer that exits after each run) and accepts the second deliberately: the ingester runs as root and reads every user's `~/.claude/projects`. It opens files with `O_NOFOLLOW`, skips symlinks, and only reads files owned by the home directory's owner.

ADR-0025's statement that the on-disk path has no retention limit is superseded: local transcripts are bounded at 180 days, and the long-term copy is this store.

## Consequences

- One more stateful service to operate, with its own alerts: `ClaudeSessionsDBDown`, `ClaudeSessionsIngestStale`, `ClaudeSessionsBackupStale`, `ClaudeSessionsBackupNeverRun`.
- Schema changes after the first deploy are applied by hand as the admin user and recorded in `stacks/claude-sessions/files/schema.sql`; the image's initdb only runs on an empty volume.
- Storage grows with use: about 7.6 GB of raw transcripts a month box-wide, about 4x smaller once stored. The PVC autoresizes to 200 GiB.
- Cluster agents (for example claude-agent-service) write transcripts inside pods and are not covered.

## Update 2026-11-11: the rest of ~/.claude and ~/.codex

For the disposable devvm (`docs/plans/2026-11-11-disposable-devvm.md`) the ingester now also reads each user's `~/.claude` and `~/.codex` outside `projects/`, into `claude.home_files` and `claude.home_lines`, and `homelab claude-sessions restore` writes them back. The same root, `O_NOFOLLOW` and owner rules apply. Point 6 above changes for these files only: credentials and caches are never read into the store, and settings files are stored with their secret values redacted, because unlike transcripts they hold standing keys rather than incidental tool output.

## Open questions

- How large the text indexes get relative to the data at full scale. The trial load was one session.
- Whether non-admin users should query their own sessions. That needs a ClickHouse user per OS user with a row policy.
