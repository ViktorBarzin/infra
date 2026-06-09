# Wealth Dashboard Consolidation — Design (2026-06-01)

## Goal

The `wealth` Grafana dashboard (UID `wealth`) has grown to **36 panels** with
heavy duplication. Consolidate to **~17 panels with ZERO metric loss** by
merging redundant panels, and fix the projection's empty-by-default problem.
Philosophy (user-locked): *merge duplicates, keep every metric* — no metric the
user tracks today is removed.

## Current state — 36 panels, duplication clusters

| Cluster | Panels today | Issue |
|---|---|---|
| **1. NW/contribution/growth over time** | "Net worth — total over time", "Net contribution vs market value", "Growth (market value − contribution) over time" | All restate `NW = contribution + growth` |
| **2. Returns/deltas stat cards** | "12mo return/contrib/gain" (3) + "Δ 1d/7d/30d/90d" × (all/mkt) (8) = 11 cards | Same idea, many windows |
| **3. Net pay vs market gain** | "…cumulative", "…per year", "…per month" (3) | Same comparison, 3 grains |
| **4. Yearly bars** | "Yearly investment return %" + "Annual change decomposition" (2) | Same yearly data, two encodings |
| Projection row (5) | text + 3 stats + projection chart | Stats duplicate Overview; chart empty by default (shared time-range) |

## Target layout — collapsed rows

### Row: Overview (expanded by default)
- **Keep** 4 snapshot stats: Net worth · Net contribution · Growth · ROI%.
- **NEW "Returns" table** ← merges cluster 2 (11 cards). `table` panel: one row
  per window (1d / 7d / 30d / 90d / 12mo), columns **Δ all £ · Δ market £ ·
  return %**. Reuses the existing per-window latest-vs-N-days-ago SQL, UNION'd
  into 5 rows. Preserves every value (12mo contrib = Δall − Δmkt) and adds
  return-% for the short windows.

### Row: Net worth over time
- **NEW merged timeseries** ← cluster 1: two lines — `net_contribution` and
  `total_value` (market value) — with the **growth gap shaded** (fillBelowTo /
  area between). Optionally a 3rd faint "growth" line (= total_value −
  net_contribution). Reuses the "Net contribution vs market value" query.
- **Keep** "Per-account stacked — total value" · "Cash vs invested (stacked)".

### Row: Returns & contributions
- **NEW yearly combo** ← cluster 4: timeseries panel, `contributions` +
  `market_gain` as **bars** (drawStyle=bars via per-series override) + a
  **`return_pct` line on a right Y-axis**. One query returns
  `year, contributions, market_gain, return_pct` (merges the two existing
  yearly queries — both already share the `yearly`/`ep` CTEs).
- **Keep** "Monthly contributions vs market gain" · "Per-account ROI %".

### Row: Income vs market
- **NEW merged "Net pay vs market gain"** ← cluster 3: one timeseries + a
  **`$grain` custom variable** (`cumulative` / `yearly` / `monthly`). The rawSql
  switches bucketing on `$grain`. Default `cumulative`.

### Row: Holdings — **Keep** Positions · Activity log
### Row: RSUs (META) — **Keep** vest cadence · realized PNL

### Row: Projections (rebuilt)
- **Rebuild the projection chart as a Trend panel** (`type: trend`): numeric
  x-axis = **years from today** (0…`$horizon_years`), y = Low / Base / High /
  Historical / "Base, no new contributions". The Trend panel renders smooth
  multi-series lines on a numeric x — **independent of the dashboard time
  range** — so it is ALWAYS visible (fixes empty-by-default). SQL: same FV math
  as today, but emit `m.n/12.0 AS years_from_now` instead of a timestamp; format
  `table`; panel `xField = years_from_now`. Carry over the dashed/dotted line
  overrides + GBP unit.
- **Drop** the 3 projection-row stat cards (NW today / Historical return /
  Monthly contribution) — already in Overview (return table + snapshot). **Keep**
  the "How to view" text panel only if still useful (with Trend it's no longer
  needed — drop it too). **Keep** the 5 template vars (rate_low/base/high,
  monthly_contribution, horizon_years).

## Panel count: 36 → ~17
4 snapshot + returns table + nw-over-time + per-account + cash-vs-invested +
yearly-combo + monthly-contrib + per-account-ROI + net-pay(merged) + positions +
activity-log + meta-cadence + meta-pnl + projection-trend = **~17**.

## Merge SQL notes (validate each against live wealth-pg before deploy)
- **Returns table**: 5 `SELECT`s (one per window) UNION ALL, each computing
  `Δall = nw_now − nw_{ago}`, `Δmkt = Δall − (contrib_now − contrib_{ago})`,
  `ret% = Δmkt / (nw_{ago} + 0.5·Δcontrib)·100` (Modified Dietz, the existing
  formula). Window→interval: 1d/7d/30d/90d/12mo.
- **Yearly combo**: extend the "Annual change decomposition" query (already has
  `contributions`, `market_gain` per year) to also emit `return_pct` (the
  "Yearly investment return %" formula) — same `ep` CTE.
- **Net-pay `$grain`**: one query; `cumulative` = running sums, `yearly`/`monthly`
  = period-end deltas (reuse the month-end/year-end delta pattern shipped today).

## Build / deploy / verify
1. One-off Python builder (`/tmp`, outside repo) loads `wealth.json`: removes the
   merged-away panels by title, adds the new merged panels + `$grain` var,
   rebuilds the projection as a Trend panel, wraps everything in collapsed rows,
   assigns unique ids + clean gridPos. Clone existing panels for schema-39
   fidelity where possible.
2. Validate: `json.load`; unique ids; spot-run every new/merged target's SQL
   against live `wealth-pg` (the pg-sync sidecar) with default var values.
3. Deploy: `scripts/tg apply -target='module.monitoring.kubernetes_config_map.grafana_dashboards["wealth.json"]'`
   (targeted — monitoring stack carries unrelated drift). `git rebase --autostash
   forgejo/master` before push (shared repo).
4. Verify: ConfigMap == local file; user eyeballs each row in Grafana (esp. the
   Trend projection renders without touching the time picker, and the returns
   table + merged panels show the right numbers).

## Risks
- **Trend panel** is flagged experimental (since v10.0) but available in v11.2;
  confirm `xField` + query `format=table` at build time.
- **Bars + line on one timeseries** (yearly combo) needs per-series `drawStyle`
  overrides + a second Y-axis override — verify rendering.
- **`$grain` net-pay** SQL is the fiddliest merge; validate all 3 grains.
- Reorganizing into rows reshuffles gridPos for the whole dashboard — the
  builder must lay out rows top-to-bottom without overlaps.
- Keep the contribution-correctness fixes (LOCF view, month-end deltas) intact —
  the merged panels read the same `dav_corrected` view.

## Out of scope
- The `dav_corrected` view + the Fidelity growth-timing cosmetic (separate).
- No new metrics — pure consolidation.
