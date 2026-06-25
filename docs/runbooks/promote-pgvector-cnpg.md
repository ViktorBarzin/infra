# Runbook: Promote pgvector onto the shared CNPG `pg-cluster`

Enable the PostgreSQL `vector` extension (pgvector) on the shared CloudNativePG
cluster `pg-cluster` (namespace `dbaas`) so claude-memory's hybrid-recall dense
leg can use `halfvec(1024)` + an HNSW index. This is done by swapping the CNPG
**operand image** to one that bundles pgvector, then creating the extension in
the `claude_memory` database as a superuser.

> **This is a shared-cluster maintenance operation, not an app deploy.** The
> operand-image swap rolls **every** `pg-cluster` tenant (~20 databases) and
> incurs a brief primary **write outage**. Treat it like planned DB maintenance:
> presence-claim, maintenance window, backup-first, staged, reversible.

The Terraform for this is **staged on branch `wizard/promote-pgvector-cnpg`**
(commit lands the image swap + the `CREATE EXTENSION` init line). Nothing has
been applied. This runbook is the procedure to promote it.

## What's staged (the code half)

| File | Change |
|------|--------|
| `stacks/dbaas/modules/dbaas/main.tf` | `null_resource.pg_cluster`: `imageName` + `triggers.image` → `ghcr.io/viktorbarzin/cnpg-postgis-pgvector:16`. `pg_params` **unchanged** (deliberate — see [Why not bump pg_params](#why-not-bump-pg_params)). |
| `stacks/dbaas/modules/dbaas/postgres/pgvector-postgis.Dockerfile` | Thin `FROM ghcr.io/cloudnative-pg/postgis:16` + `postgresql-16-pgvector`; build-time assert pgvector ≥ 0.7.0. Built off-cluster via GHA → ghcr (ADR-0002). |
| `stacks/claude-memory/main.tf` | `kubernetes_job.db_init`: adds `CREATE EXTENSION IF NOT EXISTS vector` against the `claude_memory` DB as the `root` superuser, tolerant if pgvector isn't in the image yet. |

The matching Alembic migration `005_add_embeddings_and_graph.py` (claude-memory-mcp
repo) also runs `CREATE EXTENSION IF NOT EXISTS vector` and **gates** the
`memories.embedding` column + HNSW index on the extension being present, so the
app no-ops safely until both the image swap AND the `MEMORY_EMBEDDINGS_ENABLED`
flag are on. App-side and infra-side are independently idempotent.

## Blast radius — the whole `pg-cluster` rolls

`pg-cluster` is the shared multi-tenant Postgres for the homelab. An operand-image
change rolls all three instances (replicas first, then the primary), so **every
tenant** sees the primary restart. Enumerate before you touch it:

**Databases provisioned inside the dbaas module** (`null_resource.pg_*_db`):
`terraform_state`, `payslip_ingest`, `job_hunter`, `tripit`, `nextcloud_todos`,
`postiz` + `temporal` + `temporal_visibility` (3, postiz stack),
`wealthfolio_sync`, `fire_planner`, `instagram_poster`.

**App stacks that connect to `postgresql.dbaas` / `var.postgresql_host`**
(own DB-init or Vault-rotated roles): `affine`, `authentik` (via PgBouncer),
`claude-memory`, `dawarich`, `fire-planner`, `goldmane-edge-aggregator`,
`hackmd`, `health` (apple-health-data), `linkwarden`, `n8n`, `rybbit`,
`tandoor`, `trading-bot`, plus `forgejo`/`woodpecker` per
`docs/architecture/databases.md`.

That is **~20 tenants**. Re-derive the live list at promotion time — don't trust
this snapshot:

```bash
# Tenant stacks referencing the shared PG host (read-only):
grep -rl "postgresql_host\|postgresql.dbaas\|pg-cluster" --include="*.tf" stacks/ | sort -u
# Live databases on the cluster:
PRIMARY=$(kubectl get cluster -n dbaas pg-cluster -o jsonpath='{.status.currentPrimary}')
kubectl exec -n dbaas "$PRIMARY" -c postgres -- psql -U postgres -tAc \
  "SELECT datname FROM pg_database WHERE datistemplate=false ORDER BY 1;"
```

> **Not** on `pg-cluster` (do not worry about these): **Immich** runs its OWN
> Postgres (`immich-postgresql.immich`, image `…/postgres:15-vectorchord…`), and
> the MySQL tenants are a separate engine. The legacy
> `stacks/dbaas/modules/dbaas/postgres/postgres_Dockerfile` (pgvecto-rs) is dead
> code for the retired NFS Postgres — ignore it.

## The write-outage model (restart, not seamless HA)

The CNPG operator is helm chart `0.27.1` (operator ~1.27.x). The cluster sets
**no** `primaryUpdateMethod` / `primaryUpdateStrategy`, so CNPG defaults apply:

- `primaryUpdateMethod: restart` (default since v1.20), `primaryUpdateStrategy: unsupervised`.
- **But an image change cannot be applied with an in-place restart** — CNPG
  forces a **switchover** for image upgrades. With `unsupervised` this is fully
  automated: replicas update first, a caught-up replica is promoted, the old
  primary updates last.
- Net effect: a **brief cluster-wide write interruption** (seconds — the
  switchover/restart gap) for all ~20 tenants, plus a short read blip per replica
  as each cycles. This is **not** a zero-downtime rolling event; do not sell it as
  "HA maintained." Apps with retry/reconnect (most here, via PgBouncer + Vault
  creds) ride it out; anything mid-transaction at the switchover instant errors
  and must retry.

Pick a low-traffic maintenance window accordingly.

### Why not bump `pg_params`

CNPG **rejects changing `imageName` and PostgreSQL `parameters` in the same
apply** under a switchover (the new config could be invalid on pods still running
the old image — e.g. a `shared_preload_libraries` entry the old image lacks). The
staged change therefore bumps **only** `imageName` + `triggers.image` and leaves
`pg_params` (`v3-shared1024-walcomp-workmem16-max200`) untouched. **pgvector needs
no GUC / no `shared_preload_libraries`** (unlike the dead pgvecto-rs image), so
there is nothing to add. If a future change ever needs both, do them as two
sequential applies (image first, settle, then params).

## Pre-checks (do these BEFORE applying)

### 1. PostGIS-tenant pre-check (decides the image)

The current operand `ghcr.io/cloudnative-pg/postgis:16` bundles **PostGIS but not
pgvector**. The CNPG `standard` operand flavor is the reverse — it bundles
**pgvector but DROPS PostGIS**. So you must know whether any tenant actually uses
the PostGIS extension before choosing the image.

```bash
PRIMARY=$(kubectl get cluster -n dbaas pg-cluster -o jsonpath='{.status.currentPrimary}')
# Any database with PostGIS (or its companions) installed?
for db in $(kubectl exec -n dbaas "$PRIMARY" -c postgres -- psql -U postgres -tAc \
  "SELECT datname FROM pg_database WHERE datistemplate=false"); do
  kubectl exec -n dbaas "$PRIMARY" -c postgres -- psql -U postgres -d "$db" -tAc \
    "SELECT '$db', extname FROM pg_extension WHERE extname IN ('postgis','postgis_topology','postgis_raster');"
done
```

- **dawarich** is the most likely PostGIS user (location/GPS app). As of staging,
  no tenant's Terraform issues `CREATE EXTENSION postgis` — `postgis:16` looks to
  have been a feature-parity carry-over from the old kitchen-sink image
  (`viktorbarzin/postgres:16-master`), not a hard dependency. **Confirm with the
  query above, not this note.**

**Image decision:**

| Pre-check result | Image to use | Why |
|---|---|---|
| **No** tenant uses PostGIS | `ghcr.io/cloudnative-pg/postgresql:16-standard-bookworm` (pull-only, no build) | Bundles pgvector; simplest; drops PostGIS (safe since unused). Bookworm = collation parity (below). |
| **Any** tenant uses PostGIS | `ghcr.io/viktorbarzin/cnpg-postgis-pgvector:16` (the staged thin Dockerfile) | Keeps PostGIS + adds pgvector + bookworm base. |

The staged default is the **thin PostGIS-preserving image** — it is correct
regardless of the pre-check, so it never drops an extension out from under a
tenant. If the pre-check is clean and you prefer the pull-only standard image,
edit `imageName` + `triggers.image` to `…/postgresql:16-standard-bookworm` before
applying.

### 2. Bookworm parity / collation rationale

The current `postgis:16` image is **Debian bookworm (12)** based. Both candidate
images come in `…-bookworm` and `…-trixie` (Debian 13) tags. **Use the bookworm
tag.** Jumping bookworm → trixie changes the glibc/ICU version, which can change
collation sort order and **force a `REINDEX` of text/collation-dependent indexes
across every tenant** to avoid silent index corruption. Staying on bookworm keeps
the collation provider version constant — no reindex, the swap is a pure
binary/extension change.

### 3. pgvector ≥ 0.7.0 confirmation

claude-memory uses `halfvec(1024)` + an HNSW index on `halfvec_cosine_ops`. Both
the `halfvec` type and HNSW-on-halfvec landed in **pgvector 0.7.0** (also raised
the HNSW dimension cap to 4000). The image's bundled pgvector **must be ≥ 0.7.0**.

- The thin Dockerfile already **fails the build** if `postgresql-16-pgvector` is
  older than 0.7.0 (bookworm/trixie ship ≥ 0.7.0, so this is a guardrail).
- For the standard image, confirm on a throwaway check, or after the swap:

```bash
PRIMARY=$(kubectl get cluster -n dbaas pg-cluster -o jsonpath='{.status.currentPrimary}')
kubectl exec -n dbaas "$PRIMARY" -c postgres -- psql -U postgres -tAc \
  "SELECT default_version FROM pg_available_extensions WHERE name='vector';"
# Expect >= 0.7.0
```

### 4. Build the thin image (only if using it)

Build off-cluster (GHA → ghcr; never in-cluster, ADR-0002) and pin an **immutable
tag** (content hash), e.g. `ghcr.io/viktorbarzin/cnpg-postgis-pgvector:16-<shortsha>`,
then point `imageName` + `triggers.image` at that exact tag. The `:16` rolling
tag in the staged code is a placeholder — pin a digest/SHA for the real apply so
CNPG can't silently roll on an upstream rebuild.

## Promotion procedure

### Step 0 — Claim presence + announce the window

```bash
~/code/scripts/presence claim db:pg-cluster \
  --purpose "Swap CNPG operand image to pgvector-bundled; brief primary write-outage across ~20 tenants"
```

If someone else holds `db:pg-cluster`, **defer** — coordinate, don't race. Announce
the maintenance window to anyone relying on the affected apps.

### Step 1 — Back up first (all tenants)

The cluster has **no WAL archiving / PITR** (NFS-incompatible, deferred). Your
safety net is the logical-dump CronJob. Take a fresh full dump immediately before
the swap and verify it landed:

```bash
# Trigger the existing pg_dumpall backup CronJob on demand (adjust name to live):
kubectl get cronjob -n dbaas | grep -i 'pg.*dump\|backup'
kubectl create job -n dbaas pg-backup-prepromote --from=cronjob/<pg-dump-cronjob>
kubectl wait -n dbaas --for=condition=complete job/pg-backup-prepromote --timeout=15m
# Confirm the dump file exists on NFS and is non-empty before proceeding.
```

Do not proceed without a verified, recent dump.

### Step 2 — Apply (CI, owned-app GitOps)

Infra is GitOps: land the staged branch to `master` and **CI applies it** — do
**not** run `terragrunt apply` by hand against the live cluster, and do **not**
`kubectl apply` the cluster manifest directly.

```bash
# From the staged worktree, after merging latest master in and validating:
git push origin HEAD:master   # CI (GHA) runs the apply
```

`terragrunt validate` for both `stacks/dbaas` and `stacks/claude-memory` is green
on the branch (run with the state backend disabled). Watch the CI apply to
completion.

### Step 3 — Watch the roll

```bash
kubectl get cluster -n dbaas pg-cluster -w          # phase → "Cluster in healthy state"
kubectl get pods -n dbaas -l cnpg.io/cluster=pg-cluster -w
# Expect: replicas recreate on the new image, a switchover, primary recreates.
```

Confirm all three instances are `Running` on the new image and the cluster reports
healthy before moving on.

### Step 4 — Create the extension

The `claude-memory-db-init` Job runs `CREATE EXTENSION IF NOT EXISTS vector`
against `claude_memory` as `root` on the next claude-memory apply (it's tolerant
if run earlier). To do it immediately / verify:

```bash
PRIMARY=$(kubectl get cluster -n dbaas pg-cluster -o jsonpath='{.status.currentPrimary}')
kubectl exec -n dbaas "$PRIMARY" -c postgres -- \
  psql -U postgres -d claude_memory -c "CREATE EXTENSION IF NOT EXISTS vector;"
kubectl exec -n dbaas "$PRIMARY" -c postgres -- \
  psql -U postgres -d claude_memory -tAc "SELECT extversion FROM pg_extension WHERE extname='vector';"
# Expect >= 0.7.0
```

`CREATE EXTENSION` is **per-database** and **superuser-only** — the `claude_memory`
role can't do it; `root` (the cluster's `enableSuperuserAccess: true` superuser)
can. Only the `claude_memory` DB needs it.

### Step 5 — Migrate + enable (claude-memory side, separate)

Run Alembic migration `005` (idempotent; now that pgvector is present it creates
the `embedding` column + HNSW index), then flip `MEMORY_EMBEDDINGS_ENABLED`. That
is the claude-memory-mcp app rollout, tracked separately — **not** part of this
cluster-maintenance runbook.

### Step 6 — Verify other tenants are healthy

Spot-check a few of the louder tenants reconnected cleanly:

```bash
kubectl get pods -A | grep -iE 'authentik|affine|dawarich|linkwarden|trading|hackmd' | grep -v Running
# (empty = good)
```

### Step 7 — Release presence

```bash
~/code/scripts/presence release db:pg-cluster
```

## Rollback

The swap is reversible by reverting the image. The extension itself is harmless to
leave in place (no GUC, no preload), but if the new image is unhealthy:

1. **Revert the image** — set `imageName` + `triggers.image` back to
   `ghcr.io/cloudnative-pg/postgis:16` (and revert the `CREATE EXTENSION` init line
   if desired) on a branch, land to master, let CI apply. CNPG rolls back to the
   old operand image the same way it rolled forward (replicas first, switchover) —
   another brief write blip.
2. If the standard image dropped a PostGIS the pre-check missed and a tenant
   breaks: revert to `postgis:16` immediately (step 1), then re-do the swap with
   the thin PostGIS-preserving image instead.
3. **Last resort (data-level problem):** restore from the Step 1 dump. Per
   `docs/architecture/databases.md` the cluster spec also documents the deeper
   rollback (re-apply old deployment yaml, revert the `postgresql` service
   selector to `app=postgresql`).
4. `DROP EXTENSION vector;` in `claude_memory` only if you need a fully clean
   revert — requires the embedding column/index to be gone first (downgrade
   migration 005).

## Notes

- **No `kubectl apply`/`edit`/`patch` on the cluster, no hand-run `terragrunt
  apply`.** Changes go through Terraform → CI (owned-app GitOps). Read-only
  `kubectl get/exec` for verification is fine.
- The CNPG `Cluster` is managed by `null_resource` + `kubectl apply` heredoc (not
  `kubernetes_manifest`) **on purpose** — the CNPG mutating webhook rewrites the
  spec, which breaks the TF provider's consistency check. Changing the
  `triggers.image` value is what forces the heredoc to re-apply.
- Keep `docs/architecture/databases.md` in sync if the operand image line changes
  (currently records `PostGIS 16: postgis:16`).

## Related

- `docs/architecture/databases.md` — CNPG / PgBouncer / tenant inventory.
- `stacks/dbaas/modules/dbaas/main.tf` — `null_resource.pg_cluster` (the spec).
- `stacks/claude-memory/main.tf` — `kubernetes_job.db_init` (the extension).
- claude-memory-mcp repo: `migrations/versions/005_add_embeddings_and_graph.py`,
  ADR-0002 (SQLite stays lexical), ADR-0003 (sensitive rows never embedded),
  ADR-0006 (halfvec(1024) + HNSW, pgvector ≥ 0.7.0).
