# homelab net/dns/metrics/logs verbs: endpoint resolution as the unit of value

v0.5 adds `net`/`dns`/`metrics`/`logs`. These were chosen against an explicit
test the user posed mid-build: *does the verb save reasoning, or only typing?* A
wrapper over a command already known fluently (plain `ssh`, `vault kv get`) saves
keystrokes but not thought. These four save thought — the reasoning they encode
is **which endpoint, reached how, with what auth/URL shape** — re-derived every
time otherwise. (That same test deprioritized `node ssh` aliasing and `secret
get`, which are thin wrappers; see the session discussion.)

## Decisions

- **Internal ingresses, reached via the LB.** Everything routes through the
  Traefik LB by dialing `10.0.20.203` with the URL host preserved as SNI — the
  Go form of the house `curl --resolve host:443:10.0.20.203` pattern
  (`probe.go: clientDialingIP`). Verified live before building: Prometheus
  (`prometheus-query.viktorbarzin.lan`) and Loki (`loki.viktorbarzin.lan`) both
  answer JSON over the LB with **no auth gate and no port-forward** — so these
  stay clean HTTP clients, not kubectl wrappers.
- **`net check` is two-legged on purpose.** It resolves the host via public DNS
  (→ Cloudflare) AND dials the internal LB, reporting both — because the useful
  question is *where* a break is (CF edge vs the app vs the LB path), which a
  single curl can't answer. The external leg forces public resolution (the devvm
  resolver is split-horizon and would otherwise hit the LB for both).
- **`metrics alerts` uses the `ALERTS` series, not `/api/v1/alerts`.**
  `prometheus-query.*` is a query-only frontend (404 on `/api/v1/alerts`), and
  Alertmanager has no LB ingress (the alert-digest reads it in-cluster). Firing
  alerts are exposed as the synthetic `ALERTS{alertstate="firing"}` time series,
  queryable through the working endpoint — so no new dependency.
- **Deliberately NOT built:** in-cluster-only endpoints (Alertmanager v2,
  raw `*.svc` services) that would force port-forward/`kubectl run`. The
  reasoning-savings there don't beat the added moving parts; kept out of scope.
- **No `node`/`secret` group.** Same test: their high-volume parts are
  command-wrappers (low savings); only compound node ops (serial console, VM
  wait, fan-out) would qualify, and those are lower-frequency. Left unbuilt
  unless a concrete pain surfaces — the high-value deterministic surface
  (tf/work/ci/k8s/memory + these probes) is now covered.
