# ADR-0024: Repowise is a cluster-hosted, master-scope index on a single-pod block volume

- **Status:** Accepted
- **Date:** 2026-08-14
- **Deciders:** Viktor
- **Design:** `docs/plans/2026-08-14-repowise-corpus-index-design.md`

## Context

We wanted repowise's codebase intelligence — dependency graph, git analytics,
code health, cross-repo contracts — available to our AI agents, over MCP, across
all of our first-party repositories.

repowise supports two deployment shapes, and they are not equivalent:

- **Per-user local**: `pipx install repowise`, index `~/code` in place, MCP over
  stdio. Indexes the live working tree, including uncommitted edits.
- **In-cluster service**: one shared index of clones, MCP over HTTP.

Three properties of the tool constrain any in-cluster deployment, and none are
obvious from its documentation:

1. **In workspace (multi-repo) mode, each repository's index is SQLite inside
   that repository's clone**, and the path is hard-coded —
   `create_engine(f"sqlite+aiosqlite:///{db_url_posix}")` in `server/app.py`.
   `REPOWISE_DB_URL` governs only the primary registry DB. Postgres is
   effectively unavailable for a multi-repo deployment.
2. **Both the API and the MCP server write** to those SQLite files.
3. **repowise never fetches.** Its poller compares the index's
   `last_sync_commit` to the *local* clone's HEAD, so something external must
   advance that HEAD, and the built-in staleness signal is blind to how far
   behind the remote the clone itself is.

## Decision

Run repowise as a **single in-cluster service**, not per-user:

- **One pod, four containers** (api, web, mcp, sync) on **one ReadWriteOnce
  `proxmox-lvm-encrypted` volume**. Every process that writes SQLite shares the
  pod, so the database files get ordinary POSIX locking on a block device.
- **The index tracks Forgejo master**, up to about an hour behind, and is
  accepted as such. Agents use it for whole-repo shape and history; current file
  content stays the job of Read/Grep. The boundary is documented in `CLAUDE.md`
  so agents do not quote its excerpts as current code.
- **A sidecar reconciler** resolves the Corpus by rule from the Forgejo API,
  fetches what moved, and asks the API to reindex. It is a sidecar rather than a
  CronJob because a ReadWriteOnce volume cannot be mounted from a second pod.
- **Not backed up offsite.** LVM snapshots only; the whole volume is
  regenerable from Forgejo.

## Consequences

**We get** one index for everything — devvm Workstations and in-cluster
claude-agent-service jobs share it, it survives devvm rebuilds, and there is a
single dashboard. No per-user indexing cost, and one place to reason about
freshness and access.

**We accept** that the index cannot see a branch or an uncommitted edit. For the
questions these tools answer well — architecture, blast radius, hotspots,
ownership, health — that costs nothing. For "what does this function I am editing
do right now", it is the wrong tool and the docs say so.

**We accept a staleness signal we cannot use.** Because the reconciler reindexes
immediately after fetching, index and clone stay in lockstep and repowise's
`stale_warning` stays silent even when the Corpus is an hour behind Forgejo. The
Uptime Kuma push heartbeat is what actually detects a stuck Corpus; the upstream
signal only detects a stuck reindex.

**We accept single-pod availability.** One replica, `Recreate` strategy, pinned
to wherever the volume attaches. A node failure means downtime until the volume
reattaches. The index is a cache, so the cost is unavailability, never data loss.

**Reversing to per-user local installs** is cheap on the client side (each
Workstation runs `pipx install repowise` and points MCP at stdio instead) but
would mean every user re-indexing, and losing the shared dashboard and the
cross-repo graph. Reversing the storage decision is the expensive part: moving to
NFS or Postgres is blocked by the hard-coded per-repo SQLite, so it would need
upstream to change.

## Alternatives considered

**Per-user local installs (declined).** Removes the staleness gap entirely and
needs no infrastructure. Rejected because each of wizard/emo/anca would index the
42-repo Corpus separately on the devvm, with no shared dashboard and nothing for
in-cluster agent jobs to talk to.

**Postgres on the shared CNPG cluster (not available).** Would have fit the house
pattern and removed the single-writer constraint. Blocked by the hard-coded
per-repo SQLite in workspace mode; `REPOWISE_DB_URL` covers only the registry.

**NFS RWX with a CronJob reconciler (declined).** Would let the reconciler live
in its own pod and free the deployment from node pinning. Rejected because it
puts multiple SQLite writers on NFS lock semantics, which is the well-documented
route to corruption.

**Indexing feature branches too (declined).** Would narrow the staleness gap for
an agent working on a branch. Rejected as a partial fix: uncommitted edits never
reach Forgejo at all, so the gap would remain while index size and reindex cost
multiplied per branch.
