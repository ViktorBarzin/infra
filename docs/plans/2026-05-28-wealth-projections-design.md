# Wealth Net-Worth Projections — Design (2026-05-28)

## Goal

Add forward-looking net-worth projections to the existing **`wealth`**
Grafana dashboard. Answer: *"given certain growth rates, where does my
net worth go?"* — with the growth rate sourced either from **fixed
values** (editable) or from my **own historical return** (derived from
the data). Show both pure-compounding and contributing-saver
trajectories.

## Existing state (what we build on)

- **Dashboard**: `wealth.json` (UID `wealth`, 28 panels, Finance
  folder), provisioned as a ConfigMap consumed by the Grafana dashboard
  sidecar. Datasource: **`wealth-pg`** (Postgres, populated by
  `wealthfolio-sync` ETL). Default time range `now-180d/now`. **No
  template variables today.**
- **Source view `dav_corrected`** (`infra/stacks/wealthfolio/main.tf`):
  wraps `daily_account_valuation`, correcting `net_contribution` by
  removing synthetic Fidelity-pension and Schwab-RSU flows so returns
  aren't distorted. **All return/contribution panels read this view, and
  so must the projection.**
- **Net worth (today)** = `SUM(total_value)` over the *latest-per-account*
  rows (`DISTINCT ON (account_id) … ORDER BY valuation_date DESC`). This
  is the projection start point `NW₀`.
- **Return methodology already on the dashboard** = **Modified Dietz**:
  `(nwₑ − nw₀ − flow) / (nw₀ + 0.5·flow)` where `flow = contribₑ −
  contrib₀`. Used by "12mo return" and "Yearly investment return %". The
  projection's historical rate reuses this exact formula.
- **Complete-days guard**: panels only trust dates where every active
  account reported (`COUNT(*) per date >= (SELECT COUNT(*) FROM
  accounts)`), avoiding partial-day skew (witness: memory id=1229, the
  £88k-vs-£1.03M bug). The projection reuses this guard.

## Locked decisions

| # | Decision | Choice |
|---|---|---|
| 1 | Compute engine | Pure Postgres SQL on `wealth-pg` (no new service; `fire-planner` Monte Carlo is retirement/withdrawal-oriented and a poor fit for simple growth-rate projection) |
| 2 | Display | Multiple scenario lines |
| 3 | Historical rate basis | All-time annualized Modified Dietz ("all-time CAGR") |
| 4 | Lines | Fixed low/base/high (4/7/10%, editable) **+** a line at the derived historical CAGR |
| 5 | Contributions | Support both; draw both at once at the base rate (with-contrib **and** compounding-only) |
| 6 | Horizon | 30 years (dashboard variable) |
| 7 | Placement | A **collapsed row on the existing `wealth` dashboard** (not a separate dashboard) |

## The projection panel — "Net worth — 30-year projection"

A timeseries panel. Every projected line originates from today's net
worth `NW₀`. Series:

| Series | Rate | Contributions | Line style |
|---|---|---|---|
| Net worth (actual) | — | — | solid (last 3y of real history) |
| Low | `$rate_low` (4%) | with | dashed |
| Base | `$rate_base` (7%) | with | dashed |
| Base — compounding only | `$rate_base` | none | dotted |
| High | `$rate_high` (10%) | with | dashed |
| Historical | `$hist_cagr` (derived) | with | dashed, legend `Historical (X%)` |

The visible gap between **Base** and **Base — compounding only** is the
contribution boost (how much ongoing saving adds over pure market
growth). When `$monthly_contribution = 0` the two lines coincide.

### Projection math

Per future month `n = 0 … horizon_years·12`, with monthly rate
`rm = (1+r)^(1/12) − 1`:

- **Compounding only**: `V(n) = NW₀·(1+rm)ⁿ`
- **With contributions** (ordinary annuity, end-of-period):
  `V(n) = NW₀·(1+rm)ⁿ + C·((1+rm)ⁿ − 1)/rm`
  (guard `rm = 0` → `V(n) = NW₀ + C·n`)

`C` = monthly contribution (see `$monthly_contribution` below). Future
timestamps come from `generate_series` against DB `now()` — **not** the
Grafana time picker — so the data always exists; only the axis must be
extended to display it (see Placement).

### Derived historical rate (`$hist_cagr`)

Annualized all-time Modified Dietz, computed over the complete-day
window from `dav_corrected`:

```sql
-- d0 = earliest complete day, dn = latest complete day
R_total   = (nwₙ − nw₀ − (cₙ − c₀)) / NULLIF(nw₀ + 0.5·(cₙ − c₀), 0)
hist_cagr = (power(1 + R_total, 365.25 / (dn − d0)) − 1) · 100   -- percent
```

This extends the dashboard's existing 12mo/yearly Modified-Dietz formula
to the full history, so the projected "Historical" line is consistent
with the returns already shown. Exposed as a **hidden query variable
`$hist_cagr`** so the projection line *and* its legend label reference
the same computed number.

> Alternative considered: geometric mean of the per-year Modified-Dietz
> returns (more robust to flow timing). Rejected for v1 — annualized
> all-time MD is the faithful reading of "all-time CAGR" and reuses the
> existing formula verbatim. Revisit if the single 0.5 flow-weight
> proves too crude over the multi-year window.

## Template variables (new — dashboard has none today)

| Variable | Type | Default | Purpose |
|---|---|---|---|
| `$rate_low` | textbox | `4` | low fixed annual % |
| `$rate_base` | textbox | `7` | base fixed annual % |
| `$rate_high` | textbox | `10` | high fixed annual % |
| `$monthly_contribution` | textbox | `auto` | `auto` → SQL substitutes the trailing-12-complete-month contribution run-rate; or type a number / `0` |
| `$horizon_years` | textbox | `30` | projection length |
| `$hist_cagr` | query (hidden) | computed | derived historical CAGR %, reused by line + label |

`auto` contribution run-rate (trailing 12 complete months):
`(contrib_now − contrib_12mo_ago) / 12`, read from `dav_corrected`
latest-per-account. Note: RSU vests make raw monthly contributions
lumpy; the 12-month run-rate smooths this.

## Supporting panels (same collapsed row)

- **Stat cards**: Net worth today · Historical CAGR (`$hist_cagr`) ·
  Recent monthly contribution (the `auto` value) · Projected NW at
  horizon @ base · @ historical.
- **Text panel** with one-click time-range links (see Placement).
- *(Optional)* table "Projected net worth by year" — base & historical
  columns per year, for exact figures.

## Placement & the Grafana future-axis constraint

Grafana's dashboard time range is **shared by all panels**; per-panel
overrides ("Relative time", "Time shift") only move a window relative to
the picker — neither can set a panel's end to `now+30y` while other
panels stay at `now-180d` (verified against Grafana v11.2 docs;
dashboard `schemaVersion` 39). So a 30-year future axis cannot coexist
on-screen with the 28 history panels without manual time changes.

Resolution (minimizes the clunk, zero edits to existing panels):

1. **Collapsed row** "📈 Projections" at the bottom of the dashboard.
   Collapsed by default → the 28 existing panels are untouched and never
   show future whitespace.
2. **Text panel with time-range links** inside the row:
   - `Show projection range` → `?from=now-3y&to=now%2B30y` (reloads the
     dashboard with a future-inclusive axis; projection populates).
   - `Reset range` → `?from=now-180d&to=now`.
3. The dashboard **default time stays `now-180d/now`** — unchanged.
4. Projection SQL keys off DB `now()`, independent of the picker, so the
   actual-history tail (fixed `>= now()::date − interval '3 years'`)
   plus the 30-year projection both render once the range is extended.

This honors "one dashboard, nothing extra to maintain" while making the
future-axis switch a single click.

## Data flow / SQL building blocks

- **Target A (projection, wide format)**: one row per future month;
  columns `time, proj_low, proj_base, proj_base_nocontrib, proj_high,
  proj_hist`. Grafana renders each numeric column as a series. Row `n=0`
  emits `NW₀` for all columns so lines start exactly at today.
- **Target B (actual history)**: `valuation_date, "Net worth (actual)"`
  over complete days, last 3 years. Grafana merges A+B on the time
  field; the actual series' final point (~today) meets the projections'
  `n=0` point.
- Both reuse the `latest-per-account` + `complete-days` CTEs verbatim
  from existing panels, against `dav_corrected`.
- Field overrides set line styles (solid/dashed/dotted) and the dynamic
  `Historical (${hist_cagr}%)` display name.

## Scope — what does NOT change

- The 28 existing panels, the `wealth-pg` datasource, the `dav_corrected`
  view, `wealthfolio-sync`, and the dashboard's default time range.
- No new Kubernetes resources, no new service, no `fire-planner` changes.
- Only additions to `wealth.json`: 1 collapsed row, ~7 panels, ~6
  template variables, 2 in-dashboard time-range links.

## Deployment

1. Claim presence: `scripts/presence claim stack:monitoring --purpose
   "wealth dashboard projections"`.
2. Edit `infra/stacks/monitoring/modules/monitoring/dashboards/wealth.json`.
3. `scripts/tg apply` the `monitoring` stack → ConfigMap updates → the
   Grafana dashboard sidecar reloads `wealth` (no Grafana restart).
4. Verify in Grafana (see below). This is Terraform-managed — no
   `kubectl apply`/manual edits (infra Terraform-only rule).

## Verification plan

Dashboards aren't unit-testable, so verification is data + visual:

1. **SQL pre-validation** against live `wealth-pg` (psql): run the
   `$hist_cagr` query and the projection query; sanity-check `NW₀` matches
   the existing "Net worth (current)" stat, `hist_cagr` is in a plausible
   band, and `proj_base` at `n=0` equals `NW₀`, growing monotonically.
2. **JSON validity**: `python -c "json.load(open('wealth.json'))"` and
   unique panel `id`s / sane `gridPos`.
3. **Visual** (after apply): expand the Projections row, click `Show
   projection range`, confirm 5 projected lines + actual history flow
   continuously from today; toggle `$monthly_contribution` between `auto`
   and `0` and confirm the Base / Base-compounding-only gap opens/closes;
   confirm `Reset range` restores the normal view and the 28 panels are
   unaffected.

## Risks / edge cases

- **Rate 0%** → `rm = 0` divide-by-zero — guarded in the annuity term.
- **Negative historical CAGR** (portfolio down all-time) → declining
  projection line; still valid.
- **Short history (<1y)** → annualization extrapolates a noisy rate; the
  `Historical` line is unreliable until ~1y of data. Acceptable; note in
  panel description.
- **Lumpy RSU vests** skew raw monthly contribution → trailing-12-month
  run-rate smooths it; the user can override the number anytime.
- **JSON churn**: must keep `wealth.json` valid and panel ids unique;
  the row is additive at the end to limit blast radius.
- **Docs**: per execution.md §7, update any affected
  `infra/docs/architecture` / service-catalog references for the wealth
  dashboard in the same commit (likely none beyond this plan pair).

## Open questions

None — all design decisions resolved with the user (architecture,
display, historical-rate basis, line composition, contribution
rendering, horizon, placement).
