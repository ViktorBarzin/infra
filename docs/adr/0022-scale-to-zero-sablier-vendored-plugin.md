# ADR-0022: Scale-to-zero via Sablier with a vendored Traefik local plugin

Date: 2026-07-12
Status: Accepted

## Context

The cluster is memory-bound (nodes 24–59% mem, CPU 5–23%) and its incident
history is resource exhaustion, not load. ~20 HTTP services are hand-parked at
`replicas=0` and hand-woken with `kubectl scale` when needed; dozens more run
24/7 with near-zero traffic (`traefik_service_requests_total` shows trek,
health, wealthfolio, drone-logbook et al. at ≈0 req/7d). One bespoke
wake-on-request implementation already exists (`stacks/android-emulator/gate.tf`)
and proves the pattern, but doesn't generalize to 20+ services.

Constraints that shaped the choice:

- **Traefik v3 is the sole ingress**, with Authentik forward-auth in the
  middleware chain. A prior Yaegi plugin (crowdsec-bouncer) broke on Traefik
  3.7.5 and was removed — Yaegi fragility is a proven local pain point.
  Additionally, Traefik ≥3.5.3 re-validates catalog plugins against
  `plugins.traefik.io` at startup; a transient registry failure disables all
  catalog plugins (traefik#13005).
- **Uptime Kuma + blackbox probe most services.** Any wake-on-request layer
  without probe exclusion keeps everything permanently awake (or flapping).
- **Terraform-only mutations** with daily drift detection: whatever mutates
  `spec.replicas` must coexist with `terragrunt apply`.
- Zero cost; prefer maintained OSS over custom (reuse-before-building).

Options surveyed (July 2026): Sablier v1.15.0, Elasti v0.1.25, KEDA
http-add-on v0.15 (beta), Knative Serving, Snorlax (dormant), kube-green
(calendar-only), generalizing gate.py (custom).

## Decision

Adopt **Sablier** (v1.15+) with its Traefik middleware plugin, deployed and
configured so that its two real risks are structurally bounded:

1. **The plugin is vendored as a Traefik *local* plugin, pinned to an exact
   version** — mounted into the Traefik pods from repo-controlled source,
   never fetched from `plugins.traefik.io`. Immune to the registry-coupling
   failure (traefik#13005); plugin upgrades are deliberate re-vendor commits,
   decoupled from Traefik chart bumps, and the plugin is re-validated
   explicitly on every Traefik upgrade.
2. **`failOpen: true` on every sablier middleware** — Sablier or plugin
   failure degrades to "no scale-to-zero" (running apps unaffected; sleeping
   apps 503 until it recovers), never to a blocked request path. Strictly
   better than today's hand-parked state.
3. **Blocking strategy everywhere** (hold the first request; no waiting
   page); `sessionDuration: 3h` default; probes excluded via a shared
   `ignoreUserAgent` list so monitors never wake services (enrolled monitors
   become shallow by accepted trade-off).
4. **Enrollment is explicit HCL**: an `ingress_factory` `sablier` variable +
   `sablier.enable`/`sablier.group` Deployment labels + `replicas` in
   `lifecycle.ignore_changes` marked `# SABLIER_MANAGED_REPLICAS`.

Rejected:

- **KEDA http-add-on** — beta with breaking releases, a permanent fail-closed
  interceptor tier (~8 always-on pods), and no probe exclusion.
- **Elasti** — elegant (in-path only at zero, PromQL triggers) but pre-1.0 and
  no probe exclusion → monitored services wake-flap.
- **Knative** — rewrite of every enrolled manifest + own networking layer;
  experimental Traefik support. Grossly oversized for the need.
- **Snorlax** — unmaintained since 2025-01; rewrites Ingress objects →
  permanent Terraform drift.
- **Custom (generalized gate.py)** — owning a controller forever when a
  maintained OSS fit exists violates reuse-before-building.

## Consequences

- A Yaegi plugin re-enters the request path of enrolled services — accepted
  with the vendor+pin+failOpen bounds above; upstream issue #44 (intermittent
  middleware bypass on k8s+v3) is a watch item whose worst case, under
  failOpen semantics, is a request reaching a sleeping service's 503.
- Traefik needs `allowEmptyServices: true` (cluster-wide provider setting) so
  routers to 0-endpoint Services stay registered.
- Enrolled services' Uptime Kuma monitors are shallow (green = edge + wake
  layer); the deep signal is the new `SablierWakeFailed` alert (enrolled
  deployment desired>0 & unavailable>5m). Keyword monitors must be switched
  to status-only at enrollment.
- WebSocket-dependent apps cannot enroll until upstream #26 (WS doesn't
  refresh sessions) is fixed.
- GPU tenants enroll only after the ADR-0016 VRAM budget retune, with honest
  `viktorbarzin.me/gpumem` declarations and shorter sessions. A workload is
  managed by Sablier **or** the GPU demand-gate (`stacks/tts`), never both —
  chatterbox-tts stays on the demand-gate unless deliberately migrated.
- Full design + rollout waves: `docs/plans/2026-07-12-scale-to-zero-sablier-design.md`.

## Amendment (2026-07-12, same day — wake-UX strategy revised)

Decision point 3 ("blocking strategy everywhere") was revised by Viktor after
live cold-hit UX: the **default is now the `dynamic` strategy** — an instant
themed loading page (ghost theme, 5s poll) that swaps to the app on readiness —
because the enrolled fleet turned out to be almost entirely browser UIs, and
the held request surfaced as a naked 503/524 on cold hits. `blocking` remains
a per-service override for API-shaped paths (first user: affine, whose
desktop/mobile sync clients would choke on a 200 HTML interstitial). Two
hardenings landed with the revision: every enrolled deployment carries
`sablier.ready-after: "5s"` (settling delay covering Traefik endpoint
propagation), and the middleware resource moved to `kubectl_manifest` (the
hashicorp provider's type inference breaks on in-place strategy shape
changes). Everything else in this ADR stands. Details: design doc
As-built corrections #8.
