# Upgrade bd (beads CLI) across the fleet

Last updated: 2026-10-20 (bd 1.0.x to 1.3.1, schema v32 to v66)

The shared beads database (`code` on the `dolt` Deployment in `beads-server`,
`10.0.20.200:3306`) is read and written by every `bd` client. A `bd` release
that moves the schema changes what every client needs, so a version bump is a
fleet change rather than a single image rebuild.

## Clients of the shared database

| Client | Where the version is set | Notes |
|---|---|---|
| devvm `bd` (wizard; emo's `~/.local/bin/bd` links to it) | `playbooks/devvm.yml`: `devvm_bd_version`, `devvm_bd_sha256` | `/usr/local/bin/bd` is a wrapper that sets `BD_DISABLE_METRICS=1` and runs `/usr/local/lib/bd/<version>/bd`. `~/.local/bin/bd` links to the wrapper. |
| Claude hooks (`~/code/.claude/hooks/agent-state-context.sh`, `~/.claude/hooks/beads-*.sh`) | call `/home/wizard/.local/bin/bd` | follow the devvm `bd` |
| claude-agent-service image (agent runs, `beads-dispatcher`, `beads-reaper`, `claude-breakglass`, other CronJobs on `:latest`) | `claude-agent-service/Dockerfile`: `BD_VERSION`, `BD_COMMIT` | built from source against musl in a `golang:alpine` stage; see below |
| BeadBoard | `beadboard/Dockerfile`: `BD_VERSION`, `BD_COMMIT` (since 2026-10-20) | reads go straight to Dolt over SQL (`src/lib/read-issues-dolt.ts`), so check its queries against the new schema. Writes (new task, update, close, comment) and the swarm and mission views run `bd` in the pod, built against musl like the agent image, with `BEADS_ACTOR=beadboard` |
| dolt-workbench | generic SQL UI | not schema-specific |
| presence CLI (`~/code/scripts/presence`) | uses the `beads` database, table `presence_claims` | not touched by `bd migrate schema`, which only migrates `code` |

Only the admin account is in `code-shared`, so only wizard can open
`~/code/.beads`. Other workstation users run `bd` but have no workspace on the
shared server.

## Procedure

1. Read the release notes for every version between the current and the
   target one (`gh release view vX.Y.Z -R gastownhall/beads`), and the
   upgrade notes they link.
2. Back up with the current binary, before any client changes:
   ```bash
   B=~/backups/beads/$(date +%F); mkdir -p $B && chmod 700 $B
   cd ~/code && bd export --all -o $B/code-pre-<version>.jsonl
   kubectl -n beads-server create job --from=cronjob/dolt-backup dolt-backup-manual-$(date +%s)
   kubectl -n beads-server create job --from=cronjob/dolt-history-backup dolt-history-backup-manual-$(date +%s)
   ```
   Copy the export to `/srv/nfs/dolt-backup/bd-export/<yyyymmdd>-pre-<version>/`
   with a short-lived pod that mounts PVC `beads-dolt-backup-host`. The
   backup CronJobs only rotate directories named `20*` at the top level and
   under `history/`, so `bd-export/` is kept.
3. Rehearse on a copy. Restore the newest history backup into a scratch pod
   (`dolthub/dolt-sql-server:<server version>`, emptyDir, PVC
   `beads-dolt-backup-host` read-only; steps in `restore-dolt.md`), start
   `dolt sql-server` in it, port-forward, and point the new `bd` at it with a
   scratch `.beads/metadata.json`. Run `bd migrate schema`, `bd doctor`, and
   the commands the clients use: `list`, `ready`, `show`, `create`,
   `update --claim`, `note`, `query 'assignee=agent AND status=open' --json`,
   `close`. Run BeadBoard's `readIssuesViaDolt` against the copy. Do not run
   `CALL dolt_backup(...)` or the `dolt` CLI against the live server.
4. Ship the clients that tolerate both schemas first (BeadBoard).
5. Ship the claude-agent-service image, then apply the playbook
   (`ansible-playbook ... --tags bd`, `--check --diff` first), then run
   `bd migrate schema` once from `~/code`. Keep these three steps close
   together; see the compatibility notes below.
6. Verify: `bd doctor`, schema version
   (`SELECT max(version) FROM code.schema_migrations`), row counts against
   the pre-migration counts, a create/claim/note/close round trip on a
   throwaway bead, the hook output
   (`AGENT_STATE_CACHE_DIR=<tmp> ~/code/.claude/hooks/agent-state-context.sh --refresh`),
   a presence claim and release, BeadBoard's `/api/beads/read`, and manual
   runs of `beads-dispatcher`, `beads-reaper`, `dolt-backup` and
   `dolt-history-backup`.

## Compatibility notes from the 1.3.1 upgrade

- bd 1.3.x never migrates a shared `dolt sql-server` on open. `bd migrate
  schema` (or `BD_ALLOW_REMOTE_MIGRATE=1`) is the explicit step. The `code`
  database has no Dolt remote, so the stronger `bd migrate --force` path did
  not apply.
- Against a database at schema v32, bd 1.3.1 could not read at all
  (`table not found: leases`, a v54 table). The upstream note that an upgraded
  client reads normally before the migration assumes a v53 database. Upgraded
  clients are therefore unusable between their upgrade and the migration.
- After the migration, bd 1.0.x still reads, but its writes fail
  (`failed to create ready_issues view: table "d" does not have column
  "depends_on_id"`). Nothing is written, so the database stays intact.
- Schema v66 replaces `dependencies.depends_on_id` with
  `depends_on_issue_id`, `depends_on_wisp_id` and `depends_on_external`.
  BeadBoard selected `depends_on_id` by name; since 2026-10-20 it selects
  every column and takes whichever target column is set.
- bd 1.3 refuses to close a bead whose assignee differs from the actor
  (`reclaim or use --force`). The actor is `--actor`, then `BEADS_ACTOR`,
  then `git config user.name`, then `$USER`. The `beads-task-runner` agent
  runs bd with `--actor agent`, matching the assignee the dispatcher uses.
- bd 1.3 sends anonymous usage metrics to `gastownhall-eventsapi.com` by
  default. `BD_DISABLE_METRICS=1` (set by the devvm wrapper and the agent
  image) or `bd metrics off` turns them off.
- The 1.3.1 Linux release binary needs glibc's `fcntl64`, which Alpine's
  `gcompat` does not provide. The agent image builds bd with
  `go install -tags gms_pure_go github.com/steveyegge/beads/cmd/bd@v<version>`
  in `golang:alpine` with CGO on, the same tag and CGO setting as upstream's
  release build.
- bd 1.3 writes `.beads.gate.lock` in the workspace's parent directory and
  `.beads/dolt.gate.lock`, both mode 0600, on every run. `~/code`'s
  allowlist `.gitignore` already ignores both.
- bd 1.3 warns on every run that `dolt_server_port` in `metadata.json` is
  deprecated in favour of `.beads/dolt-server.port`. The warning goes to
  stderr and does not change which server bd uses.
- `bd doctor` compares `metadata.repo_id` with a fingerprint of the
  workspace's `origin` remote URL, or of the repo path when there is no
  remote. The `code` database was created on 2026-04-14 while `~/code` had no
  remote, so it held the path hash of `/home/wizard/code` and `bd doctor`
  reported `Repo Fingerprint: Database belongs to different repository`.
  Only `bd doctor`, `bd init` and `bd migrate` read `repo_id`. On 2026-10-20
  it was set to the fingerprint of `github.com/ViktorBarzin/monorepo` with
  `bd migrate --update-repo-id --yes` from `~/code`, then
  `bd vc commit`, after a fresh `bd export --all`.

## Rollback

The schema change is not reversed by reinstalling the old binary. Upstream's
rollback is a schema-cursor rollback
(`docs/recovery/accidental-1-2-1-release.md` in the beads repo). For a full
restore, use the pre-migration history backup (`restore-dolt.md`, "Restore a
history backup") together with the old binary
(`/usr/local/lib/bd/<old version>` on the devvm, the old `BD_VERSION` in the
image).

## 2026-10-20 run

| Step | Result |
|---|---|
| Backups | `bd export --all` with bd 1.0.0, 309 issues, at `~/backups/beads/2026-10-20/` (wizard, mode 600) and `/srv/nfs/dolt-backup/bd-export/20261020-pre-1.3.1/`; manual runs `20261020-0338` (row and history) |
| Rehearsal | history backup `20261020-0338` restored into a scratch pod; `bd migrate schema` applied 34 migrations, v32 to v66, in 24s; counts unchanged; `bd doctor` 0 errors |
| BeadBoard | `d12f6f8` deployed before the migration; read 309 issues and 45 dependencies at v32 and 311 and 45 at v66. `04c4248` added bd 1.3.1 to the image: the "bd command not found in PATH" banner is gone, and a create and close through `/api/beads/*` were recorded with actor `beadboard` |
| Agent image | `404b2757` (bd 1.3.1 built against musl) |
| devvm | playbook `--tags bd`, bd 1.3.1 at `/usr/local/lib/bd/1.3.1` |
| Live migration | 2026-10-20 04:33 UTC, 20s, v32 to v66; issues 309, comments 41, labels 115, dependencies 45, events 1250 before and after |
| Post-migration backups | `20261020-0436` (row and history), both jobs completed |
| Repo fingerprint | `repo_id` 9da9acf6 (path hash) to 807eeea9 (remote), Dolt commit `s325o7es`; `bd doctor` 0 errors; export before it at `~/backups/beads/2026-10-20/code-pre-update-repo-id-bd1.3.1.jsonl` |
