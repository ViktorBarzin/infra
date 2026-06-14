# Uptime Kuma — Context

Glossary for the uptime-kuma monitoring context. Terms only — no implementation
detail. Decisions live in `docs/adr/`.

## Glossary

**Active check (poll)** — Uptime Kuma actively probes a target on an interval
(HTTP / TCP / ping / DB). This is *polling*, not "scraping." Prometheus *scrapes*
exporters; Kuma *polls* targets. (Note: Prometheus does **not** scrape Kuma — a
separate monitoring lane.)

**Monitor** — one configured target plus its check definition.

**Internal monitor** — probes a service on its in-cluster address
(`*.svc.cluster.local`). Answers "is the service itself healthy?"

**`[External]` monitor** — probes a service via its full public path
(DNS → Cloudflare → cloudflared tunnel → Traefik). Answers "is the service
reachable the way users reach it?" Maintained one-per-externally-reachable-service
by deliberate choice (see ADR-0001).

**Heartbeat** — one recorded check result (up/down + latency), persisted to the
datastore.

**External-access divergence** — the condition where a service is healthy
*internally* but its `[External]` path is down — i.e. the shared
Cloudflare/tunnel/Traefik path is broken while the service itself is fine.
Surfaced by the `ExternalAccessDivergence` alert.
