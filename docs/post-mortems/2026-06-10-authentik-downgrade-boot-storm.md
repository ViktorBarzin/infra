# Post-mortem: Authentik downgrade boot storm + shared-PG failover (2026-06-10)

**Impact:** Authentik (and therefore forward-auth for all ~67 `auth="required"`
ingresses and every OIDC app) degraded/unavailable for ~50 minutes
(~22:20–23:10 UTC). The auth-proxy basicAuth fallback served Emergency Access
prompts during outpost-check failures. The shared CNPG primary failed over
(pg-cluster-2 → pg-cluster-1, 22:40:58 UTC), briefly disturbing every PG-backed
tenant.

**Trigger:** a routine values-only `tg apply` on `stacks/authentik` (first-time
signin speedup work — env tuning, outpost config, static-asset ingress).

## Root causes (three stacked)

1. **Helm/Keel version split → silent downgrade.** Keel (namespace
   `keel.sh/enrolled` + diun annotations) had upgraded the live authentik
   image to `2026.2.4`, while the Helm release pinned chart `2026.2.2` (whose
   appVersion drives the image tag). The values-only apply therefore rolled
   every server/worker pod BACK to `2026.2.2` against a `2026.2.4`-migrated
   database. Cores never came up healthy (`failed to proxy to backend`, plus
   Django cross-version serialized-cache warnings), and mid-storm Keel
   re-upgraded the image, adding a third ReplicaSet to the churn.

2. **Liveness budget too small for authentik's boot.** The chart-default
   liveness probe (3×10s, 3s timeout) kills a pod ~30s after the go layer
   passes the startup probe — but during a rolling restart the Python core
   still waits on authentik's DB **migration advisory lock** (60–120s+ under
   contention). kubelet kill-looped every booting pod, and each kill increased
   lock contention for the rest (thundering herd).

3. **Ghost lock holders.** Pods killed mid-migration-check left PgBouncer
   server connections `idle in transaction` still **holding the migration
   advisory lock** (observed twice: `SELECT * FROM authentik_version_history`
   idle 2+ min). Every subsequent boot serialized behind a dead client.
   PgBouncer had no `idle_transaction_timeout`, so the ghosts never expired.

**Aggravator:** `AUTHENTIK_POSTGRESQL__CONN_MAX_AGE=60` (newly made live) made
every Django thread hold its connection persistently; with PgBouncer in
*session* mode each one pins a server connection 1:1, so the restart churn
saturated all 3×(20+5) pool slots (58s/s client wait observed; authentik held
75 of 108 connections on the new primary). The shared primary's
restart/failover at 22:40 fits this storm window.

## Resolution

- Scaled workers to 0 (transient) to free pool capacity; rollout converged
  once, then re-degraded when workers returned.
- Emergency `kubectl patch` of the server liveness probe (3×10s/3s →
  6×10s/5s) — final state codified in Helm values in the same session.
- `pg_terminate_backend()` on the ghost `idle in transaction` lock holders
  (twice).
- Scaled servers to 1 so a single `2026.2.4` pod booted uncontended, then back
  to 3 — converged cleanly (51s boots, zero restarts).
- Final `tg apply` reconciled everything (image tag pinned, conn_max_age
  removed, liveness in values, pgbouncer reaper config).

## Prevention (all landed in this change)

| Cause | Fix |
|---|---|
| Helm/Keel version split | `global.image.tag` pinned in `values.yaml` to the Keel-managed live tag, with a comment requiring the pin be refreshed whenever the chart is touched. Long-term: bump the chart pin when Keel moves the image (diun notifies). |
| Liveness kill loop | `server.livenessProbe` 6×10s / 5s timeout in values (startup probe still bounds total boot at 60×10s). |
| Ghost advisory-lock holders | `idle_transaction_timeout = 300` in `pgbouncer.ini` + config-checksum annotation so ini changes actually roll pgbouncer pods. |
| Pool saturation | `CONN_MAX_AGE` removed (per-request connections are ~1–2ms through local PgBouncer; not worth pinning server connections in session mode). values.yaml carries a do-not-set warning. |

## Lessons

- **Check the live image tag against the chart pin before ANY helm-managed
  apply on a Keel-enrolled namespace.** `kubectl get deploy <x> -o
  jsonpath='{..image}'` vs the chart's appVersion — a mismatch means the apply
  is a version change, not a config change.
- A "stuck rollout" of authentik is usually the migration advisory lock:
  check `pg_locks` joined to `pg_stat_activity` for `idle in transaction`
  holders before blaming probes or resources.
- The auth-proxy basicAuth fallback worked as designed throughout (Emergency
  Access path); without it every protected app would have hard-failed.
