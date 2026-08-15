# Repowise — as-built

Codebase intelligence over the Forgejo **Corpus**, serving AI agents over MCP
and humans through a dashboard. Design rationale and the decision record live in
`docs/plans/2026-08-14-repowise-corpus-index-design.md`; this file is the
operational picture.

- **Stack:** `infra/stacks/repowise/`
- **Image:** `ghcr.io/viktorbarzin/repowise` (private), built by
  `.github/workflows/build-repowise.yml` from our own
  `stacks/repowise/docker/Dockerfile`
- **Dashboard:** <https://repowise.viktorbarzin.me> (Authentik)
- **MCP:** `https://repowise-mcp.viktorbarzin.me/mcp` (home LANs / WG only)
- **Secrets:** Vault `secret/repowise`
- **Monitors:** Kuma `Repowise` (HTTP) and `Repowise Corpus Sync` (push, id 1205)

## Shape

One pod, one image, four containers, one ReadWriteOnce
`proxmox-lvm-encrypted` volume at `/workspace`:

| Container | Port | Role |
|---|---|---|
| `api` | 7337 | REST API; the only process that runs reindex jobs |
| `web` | 3000 | Next.js dashboard; SSR calls the API over loopback |
| `mcp` | 7338 | `streamable-http` MCP transport — **no auth of its own**; started via `files/mcp_serve.py` |
| `sync` | — | the reconciler: bootstraps and maintains the Corpus |

Everything that writes SQLite shares the pod because repowise hard-codes
per-repo SQLite in workspace mode and both `api` and `mcp` write. See the design
doc for why that rules out Postgres and NFS.

On-volume layout:

```
/workspace/.repowise-workspace.yaml     workspace config (which repos, primary)
/workspace/.repowise-workspace/         cross-repo analysis
/workspace/.repowise-data/              primary DB (registry only), mounted at /data
/workspace/<repo>/                      a clone
/workspace/<repo>/.repowise/wiki.db     that repo's index
```

## Using it from an agent

Each Workstation opts in with its own token — `~/.claude.json` is per-user
mutable state and is never shared, so this is not done centrally:

```bash
# token: one of the entries in Vault secret/repowise -> bearer_tokens
claude mcp add --transport http repowise \
  https://repowise-mcp.viktorbarzin.me/mcp \
  --header "Authorization: Bearer <your-token>"
```

In-cluster jobs (claude-agent-service) can use the ClusterIP directly and skip
the ingress: `http://repowise-mcp.repowise.svc.cluster.local:7338/mcp`. Note
that path is **ungated** — see the design doc's residual risks.

**What the answers describe:** Forgejo master, as last indexed, up to about an
hour behind. Architecture, dependency graph, git hotspots, ownership, code
health, blast radius and cross-repo contracts are all sound. Current file
content is not — use Read/Grep for that, and never quote a repowise excerpt as
current code. repowise's own `stale_warning` cannot report the Forgejo lag,
because it compares the index against the local clone and we reindex right after
fetching.

## Routine operations

**Add a repo to the Corpus** — nothing to do. Create it under Forgejo `viktor/*`
with at least one commit; the next hourly pass clones, registers and indexes it.
The Corpus is the rule "not archived, not empty", not a list.

**Remove one** — archive or delete it in Forgejo. The next pass runs
`repowise workspace remove` and deletes the clone.

**Force an immediate pass** — restart the pod; the reconciler runs on start.

```bash
kubectl -n repowise rollout restart deploy/repowise
kubectl -n repowise logs deploy/repowise -c sync -f
```

**Rebuild the index from scratch** — it is entirely regenerable:

```bash
kubectl -n repowise scale deploy/repowise --replicas=0
# then clear the volume (mount it from a debug pod, or delete the PVC and
# let Terraform recreate it), and scale back up
kubectl -n repowise scale deploy/repowise --replicas=1
```

The first pass re-clones all 42 repos and reindexes. It is resumable
(`--resume`) and the heartbeat stays silent until it finishes, so expect the
sync monitor to be pending, not green, during a rebuild.

**Rotate an MCP token** — edit `bearer_tokens` in Vault `secret/repowise`, then
apply the stack. Traefik reads the list from the Middleware CR, so a single
holder can be dropped without touching the others.

**Bump the repowise version** — edit `local.image` in `stacks/repowise/main.tf`.
The daily workflow will already have built the tag; if not, run
`build-repowise.yml` with a `version` input.

## Credentials

Vault `secret/repowise`:

| Key | Purpose |
|---|---|
| `api_key` | repowise's own bearer, gating `/api`; also used by the reconciler over loopback |
| `forgejo_token` | Forgejo PAT, `read:repository` only |
| `bearer_tokens` | JSON array of per-holder tokens for `/mcp`, enforced at Traefik |
| `kuma_push_url` | heartbeat target (internal ClusterIP) |

The Forgejo token is deliberately `read:repository` and nothing more. That is
enough to clone and to call `/api/v1/repos/search`, which is why the reconciler
uses search rather than `/api/v1/users/{owner}/repos` — the latter demands
`read:user`.

## Troubleshooting

**System Map / Contracts / Co-Changes are empty.** The workspace-level layer is
built by a different job from per-repo indexing, and the API cannot build it at
all. `run_cross_repo_hooks` — co-changes across repos, HTTP/gRPC/socket/topic
contracts, the system graph, breaking-change detection, conformance — is only
reached from the CLI's workspace-update path. We run it via
`files/cross_repo.py`, in an initContainer before the API starts and again on
every reconciler pass. Measured over 42 repos: 1,055 contracts, 79 matched
links, a 60-node/68-edge system graph, in about a minute; no repo is re-indexed.

**Refresh semantics worth knowing:** the API reads those artefacts into
`app.state` once at startup and offers no reload. So rebuilding them updates the
files, but the *served* System Map only changes when the API restarts. That is
why the build runs in an initContainer. Making it live would need an upstream
reload endpoint or restarting the API container when the artefacts change.

**A repo's Documentation tab is empty.** Indexing and wiki rendering are separate
phases; the API's incremental sync does the first and not the second, so a repo
it picked up (typically one an interrupted bootstrap never reached) ends up with
a full graph and no pages. Only a **full resync** re-renders them — an
incremental sync will not backfill. The reconciler now detects this (symbols
present, pages zero) and queues up to five repairs a pass. Seen on 10 of 42 repos
after the first rollout; trading went from 0 to 323 pages.

**Architecture (or any graph view) is empty.** Check which repo the dashboard is
on. `repowise init --all` picks the workspace default itself and picks the first
alphabetically, which here is `Website` — 338 files of png/md/html/svg with no
source code, so it indexes to nothing and its graph endpoint returns
`404 Repository not found`. The reconciler now pins the default to `infra`
(`REPOWISE_DEFAULT_REPO`) on every pass. Verify with
`grep ^default_repo /workspace/.repowise-workspace.yaml`.

Two repos hold data but no communities (`claude-memory`, `tasks`) simply because
they are too small to form any. `travel-agent` is a known anomaly: its
`state.json` claims 26 pages but its `wiki.db` is empty — it is a decommissioned
repo and has not been chased down.

**Dashboard times out or is very slow.** Almost certainly indexing. repowise
serves HTTP and indexes on the same asyncio loop, and the dashboard is
server-rendered against `/api`, so while a big reindex runs the page render waits
on it. Measured 2026-08-14: during the initial index of 42 repos the page took
**22.5s**; with indexing finished the same page renders in **0.6s** and
`/api/repos` answers in ~0.4s. Check `kubectl -n repowise logs deploy/repowise -c
api --tail=5` for `job_phase_start` lines before looking anywhere else.

Beware measuring this by hand: an abandoned request keeps computing server-side.
Several timed-out probes in a row saturated the single core and made a 0.4s
endpoint look like a 92s one. Let the API settle (CPU under ~200m) before
trusting a latency number.

There is also an upstream race that shows up in the same window:
`GET /api/repos` can return 500 with `RuntimeError: dictionary changed size
during iteration` (`server/routers/repos.py`, `list_repos` iterating
`workspace_sessions` while an indexing job registers a repo DB into it).
Measured 1 in 10 calls during active indexing, 0 in 10 once idle. It clears when
indexing stops; a one-line upstream fix would be to iterate a copy.

**Dashboard loads but shows no data.** The browser needs repowise's API key,
which lives in localStorage. Open `/settings` in the dashboard and paste
`api_key` from Vault. Symptom is a working shell with failing XHR.

**Dashboard 404s on `/health` or a data path.** `/api`, `/health` and `/metrics`
must all route to the API service; `/health` and `/metrics` sit at the app root,
not under `/api`. If one is missing from `ingress_path`, it falls through to the
Next.js service.

**Sync monitor red.** Read `kubectl -n repowise logs deploy/repowise -c sync`.
Likely causes, in order: the Forgejo token expired or lost scope; a repo's
default branch was renamed; the API is not up so `POST /api/workspace/sync`
fails. One unhealthy repo does not stall the pass — it is logged and the pass
reports `failed: <names>`.

**Corpus pruned unexpectedly.** The reconciler refuses to prune when Forgejo
returns zero usable repos, so a transient API failure cannot empty the volume.
If clones did disappear, the repos were genuinely archived, emptied or deleted
upstream.

**`git` complains about dubious ownership.** The reconciler sets
`safe.directory=*` at startup. A volume restored from a snapshot with different
ownership would otherwise look like a mass repo failure.

**After an upstream bump, `no such column`.** `init_db` back-fills additive
schema drift automatically; a non-additive change needs an index rebuild (above).

**`421 Invalid Host header` from `/mcp`.** The MCP SDK's DNS-rebinding
protection. repowise constructs FastMCP with the SDK's `127.0.0.1` default, so
the SDK derives a localhost-only `Host` allowlist and keeps it even after
repowise sets the host to `0.0.0.0`. `files/mcp_serve.py` replaces that allowlist
with the names this server is actually reachable by. If you add a hostname or
rename the Service, add it there — the `MCP_SERVICE_NAME`, `MCP_NAMESPACE` and
`MCP_INGRESS_HOST` env vars on the `mcp` container feed it.

**`decision_extractor.llm_structuring_failed` or `[ollama] Connection error`
warnings.** Expected. No LLM provider is configured, so the generation pipeline
tries a provider, fails, and falls back to the deterministic template — which is
the output we want. Every repo's `.repowise/state.json` records
`docs_mode: deterministic`, confirming the mode is right; the attempt is just
upstream's fallback ordering. Nothing leaves the homelab and nothing is billed.

**The API container OOM-killed.** Sized for it as of 2026-08-15, but know the
shape before trimming. The kernel log is the place to look, not the pod events:

```bash
homelab logs query '{node="<node>"} |~ "oom-kill|Killed process"' --since 24h
```

On the 2026-08-15 kill that showed uvicorn itself at 2.67 GiB anon-rss with the
nine python worker subprocesses at 8-54 MiB each — the parent is the memory, so
lowering `REPOWISE_PARSE_WORKERS` does not address it. Working set runs
2.2-2.4 GiB steady, because in workspace mode the API holds a SQLAlchemy engine,
an FTS index and a vector store **per repo** for all 42, for the life of the
process. That is a high baseline, not a leak: it sat in a flat 2.4-3.0 GiB band
across 20 hours. Request is 2560Mi (the previous 768Mi misinformed the scheduler
badly) and the limit 5Gi. If it ever climbs past 5Gi rather than plateauing,
that would be a genuine leak and a different problem.

**Detection caveat:** `container_oom_events_total` stayed at **0** for that kill,
so the cadvisor-based `ContainerOOMKilled` alert never fired. The Loki-based
`KernelOOMKiller` alert is what caught it. Do not treat a quiet
`container_oom_events_total` as evidence there was no OOM here.

**Indexing blocks the event loop — keep the probes slack.** repowise indexes in
the same asyncio loop that serves HTTP, so a CPU-bound graph phase (betweenness
centrality over a large repo) stops `/health` answering for minutes. On
2026-08-14 a 5s/3-failure liveness probe killed the API mid-index and repeated it
on the restart, stalling the first index at 36 of 42 repos. Events showed
"Container api failed liveness probe, will be restarted" — **not** an OOM kill,
which is the easy misdiagnosis given the exit code is 137. Liveness now tolerates
~5 minutes and readiness ~90s. If you tighten them, expect this back. For the
same reason the Kuma `Repowise API` monitor needs several retries before it
alerts.

**A killed `tg apply` can orphan a resource.** If an apply is interrupted after
it creates something but before it writes state, later applies fail with
`already exists`. That happened to the Deployment during the initial rollout.
Fix: confirm with `tg state list`, then either import it or delete the live
object and re-apply. The PVC is a separate resource, so the Corpus survives
either way.

## Deliberate deviations from house convention

- **No backup CronJob**, though the convention requires one for every
  proxmox-lvm app. The Corpus is regenerable from Forgejo and is skipped in
  `scripts/daily-backup.sh`; LVM snapshots are kept for rollback.
- **Not Sablier-enrolled**, despite being a low-traffic HTTP app: the background
  polling and reindexing are the product, and parking would stop them.
- **`/metrics` is not scraped** — it reports the primary repo's DB only, so a
  fleet-wide reading would mislead.
- **Own Dockerfile rather than upstream's**, which is broken for the workspace
  build. Guarded by a layout assertion in CI.
