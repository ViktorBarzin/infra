# Wealth Net-Worth Projections — Implementation Plan

> Pairs with `2026-05-28-wealth-projections-design.md`. Built 2026-06-01.

**Goal:** Add a collapsed "Projections" row to the `wealth` Grafana dashboard
(UID `wealth`) with a 30-year multi-scenario net-worth projection, driven by
pure SQL over the (now LOCF-fixed) `dav_corrected` view.

**Architecture:** Edit `infra/stacks/monitoring/modules/monitoring/dashboards/wealth.json`
via a one-off Python builder (reliable JSON construction). Add 6 template
variables + 1 collapsed row + projection panels. Deploy via targeted
`scripts/tg apply` of the dashboard ConfigMap; Grafana sidecar reloads.

**Tech stack:** Grafana 11.2 (schemaVersion 39), Postgres datasource `wealth-pg`.

---

## Validated inputs (live, 2026-06-01)

- `nw0` (net worth today) = £1,163,011 — latest-per-account SUM(total_value).
- auto monthly contribution run-rate = £15,755/mo (trailing 12 complete months ÷ 12).
- Historical return = **trailing-3-full-year** geometric mean of per-year
  Modified-Dietz returns = **10.43%**.
- FV math verified: n=0 = nw0 for every line; base@30y ≈ £27.3M, high ≈ £52.8M.

### GOTCHA (why not "all-time CAGR")

The complete-days filter (all 7 accounts present) only reaches back to
2026-01-30 because the newest account is recent — so an "all-time CAGR over
complete days" annualised a ~4-month window into a nonsense **83.71%**. And
the true all-time geomean (17.5%) is dominated by 2021's small-base **+86%**
year and would dwarf a 30y chart. Decision (user, 2026-06-01): use the
**trailing-3-full-year** geomean (~10.4%) — represents "current returns",
chart-sane. Per-year MD returns reuse the existing "Yearly investment return %"
methodology (each year uses its own first/last obs; no all-complete requirement).

## Template variables (add to `templating.list` — dashboard has none today)

| name | type | default | hide |
|---|---|---|---|
| `rate_low` | textbox | `4` | 0 |
| `rate_base` | textbox | `7` | 0 |
| `rate_high` | textbox | `10` | 0 |
| `monthly_contribution` | textbox | `auto` | 0 |
| `horizon_years` | textbox | `30` | 0 |
| `hist_cagr` | query (datasource wealth-pg) | computed | 2 (hidden) |

`hist_cagr` query:
```sql
WITH active_count AS (SELECT COUNT(*) n FROM accounts), mc AS (SELECT MAX(valuation_date) d FROM (SELECT valuation_date, COUNT(*) c FROM dav_corrected GROUP BY valuation_date) x WHERE c >= (SELECT n FROM active_count)), yearly AS (SELECT EXTRACT(YEAR FROM valuation_date)::int yr, valuation_date, SUM(total_value) nw, SUM(net_contribution) contrib FROM dav_corrected WHERE valuation_date <= (SELECT d FROM mc) GROUP BY valuation_date), ep AS (SELECT yr, (array_agg(nw ORDER BY valuation_date))[1] nw_s, (array_agg(nw ORDER BY valuation_date DESC))[1] nw_e, (array_agg(contrib ORDER BY valuation_date))[1] c_s, (array_agg(contrib ORDER BY valuation_date DESC))[1] c_e, COUNT(*) days FROM yearly GROUP BY yr), r3 AS (SELECT (nw_e-nw_s-(c_e-c_s))/NULLIF(nw_s+0.5*(c_e-c_s),0) ret FROM ep WHERE (nw_s+0.5*(c_e-c_s))>0 AND days>=300 ORDER BY yr DESC LIMIT 3) SELECT ROUND((exp(avg(ln(1+ret)))-1)*100,2) FROM r3
```

## Panels (new collapsed row "📈 Projections", at bottom, y=200)

1. **Text panel** "How to view" with two dashboard links:
   `[Show projection range](?from=now-3y&to=now%2B30y)` /
   `[Reset](?from=now-180d&to=now)`. (h=3,w=24)
2. **Stat row** (h=4): NW today · Historical return (trailing 3y) ·
   Monthly contribution (auto) · Projected NW @ base in `$horizon_years`y.
3. **Timeseries** "Net worth — `$horizon_years`-year projection" (h=12,w=24),
   two targets (A wide projection, B actual 3y tail). Field overrides:
   actual = solid; Low/Base/High/Historical = dashed; "Base, no new
   contributions" = dotted.

### Panel 3 Target A (wide projection) — column aliases embed the rate for legends
```sql
WITH active_count AS (SELECT COUNT(*) n FROM accounts), mc AS (SELECT MAX(valuation_date) d FROM (SELECT valuation_date, COUNT(*) c FROM dav_corrected GROUP BY valuation_date) x WHERE c >= (SELECT n FROM active_count)), latest AS (SELECT DISTINCT ON (account_id) account_id, total_value, net_contribution FROM dav_corrected WHERE valuation_date <= (SELECT d FROM mc) ORDER BY account_id, valuation_date DESC), agg AS (SELECT SUM(total_value) nw0, SUM(net_contribution) c_now FROM latest), ago AS (SELECT SUM(x.nc) c_ago FROM latest l LEFT JOIN LATERAL (SELECT net_contribution nc FROM dav_corrected d WHERE d.account_id=l.account_id AND d.valuation_date <= (SELECT d FROM mc) - INTERVAL '12 months' ORDER BY d.valuation_date DESC LIMIT 1) x ON true), params AS (SELECT (SELECT nw0 FROM agg) nw0, CASE WHEN '$monthly_contribution'='auto' THEN ((SELECT c_now FROM agg)-(SELECT c_ago FROM ago))/12.0 ELSE '$monthly_contribution'::numeric END cm, ($rate_low::float)/100 rl, ($rate_base::float)/100 rb, ($rate_high::float)/100 rh, ($hist_cagr::float)/100 rhist), m AS (SELECT generate_series(0, ${horizon_years}*12) n) SELECT (now() + (m.n || ' months')::interval) AS "time", round((nw0*power(1+(power(1+rl,1/12.0)-1),m.n) + cm*((power(1+(power(1+rl,1/12.0)-1),m.n)-1)/NULLIF(power(1+rl,1/12.0)-1,0)))::numeric,0) AS "Low ($rate_low%)", round((nw0*power(1+(power(1+rb,1/12.0)-1),m.n) + cm*((power(1+(power(1+rb,1/12.0)-1),m.n)-1)/NULLIF(power(1+rb,1/12.0)-1,0)))::numeric,0) AS "Base ($rate_base%)", round((nw0*power(1+(power(1+rb,1/12.0)-1),m.n))::numeric,0) AS "Base, no new contributions", round((nw0*power(1+(power(1+rh,1/12.0)-1),m.n) + cm*((power(1+(power(1+rh,1/12.0)-1),m.n)-1)/NULLIF(power(1+rh,1/12.0)-1,0)))::numeric,0) AS "High ($rate_high%)", round((nw0*power(1+(power(1+rhist,1/12.0)-1),m.n) + cm*((power(1+(power(1+rhist,1/12.0)-1),m.n)-1)/NULLIF(power(1+rhist,1/12.0)-1,0)))::numeric,0) AS "Historical ($hist_cagr%)" FROM m, params
```

### Panel 3 Target B (actual history, 3y tail)
```sql
WITH active_count AS (SELECT COUNT(*) n FROM accounts), mc AS (SELECT MAX(valuation_date) d FROM (SELECT valuation_date, COUNT(*) c FROM dav_corrected GROUP BY valuation_date) x WHERE c >= (SELECT n FROM active_count)) SELECT valuation_date::timestamp AS "time", SUM(total_value) AS "Net worth (actual)" FROM dav_corrected WHERE valuation_date <= (SELECT d FROM mc) AND valuation_date >= now()::date - INTERVAL '3 years' GROUP BY valuation_date ORDER BY valuation_date
```

### Stat SQL
- NW today: `WITH latest AS (SELECT DISTINCT ON (account_id) total_value FROM dav_corrected d JOIN accounts a ON a.id=d.account_id ORDER BY account_id, valuation_date DESC) SELECT SUM(total_value) FROM latest`
- Historical return %: `SELECT $hist_cagr::float`
- Monthly contribution (auto): the `agg`/`ago` run-rate `((c_now)-(c_ago))/12.0`
- Projected @ base: Target-A base formula evaluated at `n = $horizon_years*12`

## Build / deploy / verify

1. **Build:** one-off Python script `/tmp/build_projection.py` (outside repo)
   loads wealth.json, appends the 6 vars + row + panels, fixes the "Net pay vs
   market gain — per month" panel (#3) to month-end deltas, writes back.
2. **Validate:** `python -c json.load`; unique panel ids; spot-run Target A/B
   against live `wealth-pg`.
3. **Deploy:** `scripts/tg apply -target=...grafana_dashboards["wealth.json"]`
   (targeted — monitoring stack has unrelated pre-existing drift).
4. **Verify:** ConfigMap carries new content; user expands the row, clicks
   "Show projection range", confirms 5 projected lines flow from today + the
   actual tail; toggles `$monthly_contribution`=0 to see the contribution gap.

## Scope notes

- Skip the optional "projected NW by year" table (YAGNI; add later if wanted).
- #3 ("Net pay vs market gain — per month") aligned to month-end deltas in the
  same build for monthly-market-gain consistency.
- Fidelity growth-timing cosmetic = NOT in scope (user deferred 2026-06-01).
