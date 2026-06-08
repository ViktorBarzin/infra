# Matrix: Synapse → tuwunel migration — Design

**Date:** 2026-06-08
**Status:** Implemented
**Stack:** `stacks/matrix` (+ `stacks/vault` cleanup)

## Context

The `matrix` homeserver ran **Synapse** (`matrixdotorg/synapse:v1.151.0`) on a
cramped `256Mi/512Mi` allocation. Synapse (Python) wants 1–2 GB; at 512Mi it was
starved. During a Slack-vs-Discord-vs-Matrix evaluation Viktor confirmed Slack
stays his primary hub, but wanted a **working, federated Matrix server kept
available "in case I need it."** The resource pain was Synapse-specific — not
inherent to Matrix — so the fix was to swap the homeserver implementation, not
abandon Matrix.

## Decision

Replace Synapse with **tuwunel v1.7.1** (Rust, RocksDB) — the
enterprise/Swiss-government-backed official successor to the (archived 2026-01-19)
conduwuit.

| Choice | Decision | Rationale |
|---|---|---|
| Homeserver | **tuwunel** (vs continuwuity) | Corporate-backed, full-time staff → best longevity for a set-and-forget server |
| Data | **Fresh start** (no migration) | No supported Synapse(Postgres)→RocksDB path; Viktor confirmed old rooms/messages disposable |
| Federation | **ON** | A backup server is only useful if it can reach the wider Matrix network |
| `server_name` | **unchanged** (`matrix.viktorbarzin.me`) | Element clients keep pointing at the same place; only a re-login needed |
| Database | **embedded RocksDB** on the existing encrypted PVC | Drops the entire CNPG dependency; local-SSD LUKS2 suits RocksDB's small writes (NFS would be wrong) |
| Registration | token-gated, then **disabled** | First user = admin; locked down after registering `@viktor` |
| Auth | **native password** | tuwunel OIDC SSO not wired — Authentik Matrix OAuth app is now orphaned (harmless) |
| Media cap | **50 MiB** | Kept under Cloudflare's 100 MB proxied-request ceiling |

## Alternatives considered

- **Keep Synapse, bump to 2 GB** — zero-migration, but stays the heavy Python
  server; rejected in favour of the lightweight Rust target Viktor asked for.
- **continuwuity** — community continuation; viable and lighter-community, but
  tuwunel's corporate backing won on longevity.
- **Synapse → tuwunel data migration** — not possible (different storage
  engines); fresh start is the only path.

## As-built

- Fully env-var configured (`TUWUNEL_*`, `__` for nested) — no TOML ConfigMap.
- tuwunel serves its own `.well-known/matrix/{client,server}` → federation
  resolves to Cloudflare-proxied `:443` (no 8448 / SRV needed).
- Ingress unchanged: `auth = "none"` (Matrix uses bearer/signed requests),
  `dns_type = "proxied"`.
- Pod `securityContext` `runAsUser/runAsGroup/fsGroup = 1000` so uid 1000 can
  write the encrypted RocksDB PVC.
- Image kept under Keel + diun semver management (`^v\d+\.\d+\.\d+$`).
