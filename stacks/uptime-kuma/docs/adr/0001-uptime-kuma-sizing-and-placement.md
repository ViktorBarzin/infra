# ADR-0001: Uptime Kuma is intentionally lean — sizing & placement

## Status
Accepted (2026-06-13)

## Context
A review was prompted by a suspicion that Kuma was "scraping too much / causing
unnecessary traffic," itself triggered by a socket.io login-timeout incident on
the monitor-sync CronJobs. Measured state at review time:

- **227 active monitors**; 209 of them at 300s intervals; **~1 check/sec** aggregate.
- Datastore: the **shared `mysql.dbaas`** (MariaDB), **~77 MB**, ~1 heartbeat
  write/sec, 30-day retention.
- **122 `[External]` monitors** (full public path) + ~105 internal.

The data did **not** support a load problem — Kuma is already lean. The
login-timeout incident was a Kuma 2.x socket.io quirk (kuma's single Node event
loop briefly stalling), fixed separately by wrapping login in a retry — not a
load issue.

## Decisions
1. **Keep Kuma as-is; do not reflexively cut monitors or intervals.** Poll rate
   (~1/s) and DB footprint (77 MB) are modest.
2. **`[External]` monitors stay per-service** (one per externally-reachable
   service), **not** a small canary set. Rejected cutting to ~6-10 canaries:
   although the Cloudflare → tunnel → Traefik path is shared infra that fails as a
   unit, per-service external probes also catch *single-service* external
   misconfig (one service's DNS / auth carve-out / route), which canaries miss.
   The ~35k Cloudflare requests/day this generates is accepted for that coverage.
3. **Datastore stays on the shared `mysql.dbaas`.** Rejected moving to
   self-contained SQLite or a dedicated DB. The coupling — Kuma depends on the
   single-instance MySQL it also helps monitor, including during that MySQL's
   8.4.9 wipe-maintenance (bead code-963q) — is acknowledged but accepted as
   low-impact for now.

## Consequences
- All three decisions are **cheap to reverse**; revisit if measured load on
  `mysql.dbaas` or Cloudflare ever becomes a real (not gut-feel) problem. This
  ADR exists mainly so that review isn't re-run from scratch.
- **Known gap:** the *internal* monitor-sync creates/updates monitors but does
  **not** prune orphans (the external sync does). Internal monitors for deleted
  services linger and need periodic manual cleanup — e.g. the stale
  "Goldilocks (VPA)" monitor (target removed with VPA on 2026-06-12) was deleted
  by hand on 2026-06-13. A *scoped* internal-prune (only deleting monitors the
  sync owns, never hand-made ones) is a possible future improvement.
