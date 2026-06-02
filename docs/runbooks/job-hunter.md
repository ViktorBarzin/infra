# Runbook: job-hunter — passive job + comp scraper

Last updated: 2026-06-02

`job-hunter` is a passive job-market + compensation scraper in the `job-hunter`
namespace. It pulls open roles from ATS boards (Greenhouse / Lever / Ashby),
HN "Who is hiring", and levels.fyi comp medians into a CNPG Postgres DB, and
serves agent-friendly CLI queries (used by the `job-hunter` Claude skill). As
of 2026-06-02 it also accumulates **dated snapshots** so comp and hiring-volume
trends can be tracked over time.

## Where things live

| Thing | Location |
|---|---|
| Source code | Forgejo `https://forgejo.viktorbarzin.me/viktor/job-hunter` (NOT in the monorepo) |
| Image | `forgejo.viktorbarzin.me/viktor/job-hunter:latest` (CI builds on push; Keel rolls the Deployment) |
| Terraform stack | `infra/stacks/job-hunter/` (`main.tf` = Deployment/Service/ESO; `cronjob.tf` = weekly refresh) |
| Database | `pg-cluster-rw.dbaas.svc.cluster.local:5432/job_hunter`, role `job_hunter` (Vault `static-creds/pg-job-hunter`, 7d rotation) |
| App secrets | Vault `secret/job-hunter` → `webhook_bearer_token`, `cdio_api_key`, `smtp_username/password`, `digest_to/from_address` |
| Grafana | `https://grafana.viktorbarzin.me` → datasource **Job Hunter** (PG, read-only) |
| Claude skill | `~/.claude/skills/job-hunter/SKILL.md` |
| Weekly scrape | CronJob `job-hunter-refresh`, **Sundays 04:00 UTC** |

## Architecture

- **Sources** (`job_hunter/sources/`): `ats` (Greenhouse/Lever/Ashby JSON APIs, ~35 companies in `config/companies.yaml`), `hn` (Algolia), `levels_fyi` (comp medians), `linkedin_guest` (opt-in), `changedetection` (`/webhook/cdio` for non-ATS careers pages in `config/cdio_watches.yaml`).
- **Tables**: `companies`, `roles`, `comp_points`, `levels`, `fx_rates` (upsert-in-place, "current state"); `comp_snapshots`, `roles_snapshots` (append-only, one row per source-row per `snapshot_date` — the dated series). Snapshots are written as a side-effect of every upsert during a refresh.
- **The ATS fetch is resilient**: a board returning a permanent 4xx (404/410/403) is skipped with a warning; 5xx/network errors retry once then skip. One dead board cannot abort the whole run (regression fixed 2026-06-02 — Elastic's 404 had been taking down every refresh). Boards are fetched concurrently (bounded semaphore, default 8 in-flight).

---

## OPS

### Is it healthy?

```bash
# CronJob exists + last schedule/success
kubectl -n job-hunter get cronjob job-hunter-refresh
# Most recent run's pods + logs
kubectl -n job-hunter get jobs -l app=job-hunter --sort-by=.metadata.creationTimestamp
kubectl -n job-hunter logs -l job-name=$(kubectl -n job-hunter get jobs -o jsonpath='{.items[-1:].metadata.name}')
# Deployment (serves the CLI / webhook) is up
kubectl -n job-hunter get deploy job-hunter
# Data freshness — newest snapshot date should advance weekly
kubectl -n job-hunter exec deploy/job-hunter -- python -m job_hunter report --days 7 | jq '.source_mix'
```

Row-count sanity (via the read-only Grafana datasource or a direct exec):

```bash
kubectl -n job-hunter exec deploy/job-hunter -- python -c "import job_hunter"  # smoke
```

### Manual refresh (off-schedule)

```bash
kubectl -n job-hunter exec deploy/job-hunter -- \
  python -m job_hunter refresh --source ats --source hn --source levels_fyi
```

Or trigger the CronJob immediately:

```bash
kubectl -n job-hunter create job --from=cronjob/job-hunter-refresh jh-manual-$(date +%s)
```

### Seed / re-snapshot the dated series

Snapshots are written automatically on every refresh. To seed a baseline from
the current tables (idempotent — one row per source-row per day):

```bash
kubectl -n job-hunter exec deploy/job-hunter -- python -m job_hunter snapshot
# back-date a snapshot if needed:
kubectl -n job-hunter exec deploy/job-hunter -- python -m job_hunter snapshot --date 2026-06-01
```

### Add an ATS company

ATS companies are scraped from `config/companies.yaml` in the **Forgejo repo**
(not the monorepo). To add one:

1. Live-probe the slug returns HTTP 200 with London roles before adding it:
   ```bash
   curl -s "https://boards-api.greenhouse.io/v1/boards/<slug>/jobs?content=true" -o /dev/null -w '%{http_code}\n'
   # Lever:  https://api.lever.co/v0/postings/<slug>?mode=json
   # Ashby:  https://api.ashbyhq.com/posting-api/job-board/<slug>?includeCompensation=true
   ```
2. Add a `{slug, display_name, ats_type, ats_id, careers_url}` block to `config/companies.yaml`, commit, push.
3. CI builds the image; Keel rolls the Deployment. The next refresh picks it up. (No Terraform change — config ships in the image.)

A board that later starts 404ing is skipped automatically; remove its entry
when the 404 is permanent (keeps logs clean).

### Add a changedetection.io watch (non-ATS firms)

Firms without a public ATS JSON API (Citadel, Two Sigma, G-Research, HRT, xAI,
Wise, Revolut, …) are diff-monitored via CDIO. Add to `config/cdio_watches.yaml`
in the Forgejo repo, then reconcile:

```bash
kubectl -n job-hunter exec deploy/job-hunter -- python -m job_hunter cdio-seed --dry-run  # preview
kubectl -n job-hunter exec deploy/job-hunter -- python -m job_hunter cdio-seed            # create
kubectl -n job-hunter exec deploy/job-hunter -- python -m job_hunter cdio-reconcile       # list
```

Changes hit `/webhook/cdio`; comp/role extraction from the diff is manual or
LLM-side (CDIO only captures the changed text).

### Applying the Terraform stack

```bash
cd infra/stacks/job-hunter
scripts/tg plan      # vault login -method=oidc first
scripts/tg apply
```

The DB password rotates every 7 days (Vault static role `pg-job-hunter`);
Reloader restarts the Deployment when the ESO-synced secret changes. The
Grafana datasource password is mirrored via a second ExternalSecret in the
`monitoring` namespace.

### Common failures

| Symptom | Cause | Fix |
|---|---|---|
| Refresh job `Error`, log shows `ats: skipping company=X — HTTP 404` | A board slug was renamed/removed | Expected — the run continues. Remove the dead slug from `companies.yaml` if permanent. |
| Refresh aborts with a traceback before any company | Pre-2026-06-02 image (no skip-on-404) | Confirm Keel rolled the new image: `kubectl -n job-hunter get deploy job-hunter -o jsonpath='{..image}'`. |
| `snapshot` / refresh fails: `relation "job_hunter.comp_snapshots" does not exist` | Migration 0004 not applied | The CronJob + Deployment run `migrate` on start. Run `kubectl -n job-hunter exec deploy/job-hunter -- python -m job_hunter migrate`. |
| `/webhook/cdio` returns 401 | `webhook_bearer_token` mismatch between Vault and the CDIO notification URL | Re-run `cdio-seed` after rotating the token; it rebuilds the `jsons://...?+Authorization=` URL. |
| Non-GBP comp looks wrong / NULL | `fx_rates` gap for the role's `posted_at` date | `kubectl -n job-hunter exec deploy/job-hunter -- python -m job_hunter backfill-fx --days 30` |
| Job OOMKilled | levels.fyi HTML parse spike across many companies | Bump the CronJob container memory limit in `cronjob.tf` (currently 1Gi). |

---

## ANALYST

### The periodic "market leaders in comp" report

This is the headline command — current leaders by p50 total comp, week-over-week
movers, new entrants, open-role counts, and sample-size caveats:

```bash
# London senior leaders, human-readable
kubectl -n job-hunter exec deploy/job-hunter -- \
  python -m job_hunter analyze --level senior --top-n 10
# All levels, JSON for downstream tools
kubectl -n job-hunter exec deploy/job-hunter -- \
  python -m job_hunter analyze --format json
```

`--trend-weeks N` sets the movers comparison window (default 12). Movers report
`available: false` until at least two snapshot dates spanning the window exist —
the series starts accumulating from the first refresh after 2026-06-02, so
12-week movers become meaningful around late August 2026.

### Query recipes

```bash
# Salary band for a slice
kubectl -n job-hunter exec deploy/job-hunter -- python -m job_hunter bands --title 'staff'
kubectl -n job-hunter exec deploy/job-hunter -- python -m job_hunter comp-band --level senior
# Per-(company, level) comp table
kubectl -n job-hunter exec deploy/job-hunter -- python -m job_hunter comp-table --location london
# Open roles, highest-confidence comp first
kubectl -n job-hunter exec deploy/job-hunter -- python -m job_hunter query --title sre --with-salary --limit 20
# Compare two firms
kubectl -n job-hunter exec deploy/job-hunter -- python -m job_hunter comp-band --company janestreet
kubectl -n job-hunter exec deploy/job-hunter -- python -m job_hunter comp-band --company optiver
```

### Trend queries (Grafana or psql against the snapshot tables)

The dated series lives in `comp_snapshots` / `roles_snapshots`. Examples (run in
Grafana's "Job Hunter" datasource, or `psql` as the `job_hunter` role):

```sql
-- Comp trend: median total comp per company over time (London)
SELECT s.snapshot_date, c.display_name,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY COALESCE(s.total_gbp, s.base_gbp)) AS p50_gbp
FROM job_hunter.comp_snapshots s
JOIN job_hunter.companies c ON c.id = s.company_id
WHERE s.location_bucket = 'london'
GROUP BY s.snapshot_date, c.display_name
ORDER BY s.snapshot_date, p50_gbp DESC;

-- Hiring-volume trend: open London roles per company per snapshot
SELECT s.snapshot_date, c.display_name, COUNT(*) AS open_roles
FROM job_hunter.roles_snapshots s
JOIN job_hunter.companies c ON c.id = s.company_id
WHERE s.primary_location = 'london'
GROUP BY s.snapshot_date, c.display_name
ORDER BY s.snapshot_date, open_roles DESC;

-- Two-snapshot diff: p50 change for one company between two dates
SELECT c.display_name, s.snapshot_date,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY COALESCE(s.total_gbp, s.base_gbp)) AS p50
FROM job_hunter.comp_snapshots s
JOIN job_hunter.companies c ON c.id = s.company_id
WHERE c.slug = 'janestreet' AND s.snapshot_date IN ('2026-06-02', '2026-08-30')
GROUP BY c.display_name, s.snapshot_date;
```

### Interpreting the numbers — caveats

- **Sample size**: `analyze` flags companies with `n < 3` as `low_confidence`. A single self-reported datapoint is anecdote, not a band — chase the p50 only where n is healthy.
- **levels.fyi bias**: comp_points are self-reported medians; they skew toward people who report (often higher earners) and lag the market by a quarter or two.
- **HFT/quant**: base comp is the disclosed figure; bonus (often the larger half) is variable and usually absent from postings. Treat HFT base as a floor, not total.
- **Currency**: all figures are GBP-normalised via ECB rates looked up by `posted_at` (7-day fallback). A FX gap shows as NULL comp, not a wrong number.
- **Movers need history**: a delta is only as good as the two snapshot dates behind it; early deltas (< full `trend_weeks` of data) compare against the earliest available snapshot and are noted as such.

## Related

- Skill: `~/.claude/skills/job-hunter/SKILL.md` (agent invocation patterns)
- Beads epic: `code-snp`
- Storage / backup context: this DB is on the shared CNPG cluster (`dbaas`), backed up by the per-db `postgresql-backup-per-db` CronJob.
