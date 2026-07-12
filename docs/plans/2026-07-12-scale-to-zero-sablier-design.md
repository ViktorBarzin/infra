# Scale-to-zero for HTTP services — Sablier wake-on-request — design

- **Date:** 2026-07-12
- **Status:** draft (decisions locked in grilling session; pending Viktor's review of this doc)
- **Owner:** Viktor (wizard)
- **Decision record:** `docs/adr/0022-scale-to-zero-sablier-vendored-plugin.md`
- **Builds on:** the hand-built wake-on-request precedent `stacks/android-emulator/gate.tf` (gate.py + idle-sleeper CronJob), Traefik per-service request metrics (`prometheus_chart_values.tpl` Traefik scrape job), ADR-0016 (T4 VRAM budget)

## Goal

Idle HTTP services release their RAM by scaling to 0 replicas, and **wake
automatically on the first request** — no more manual `kubectl scale` in either
direction. Success = the ~20 hand-parked services become self-reviving, plus a
second wave of measurably-idle running services stops burning memory 24/7.

Primary win: **memory** (nodes sit at 24–59% mem while CPU idles at 5–23%;
every post-mortem class on this cluster is resource exhaustion, not load).
Secondary win: convenience — parking is already the habit (see the ~20
`replicas=0` deployments); this removes the wake friction that habit costs.

## Decisions (locked 2026-07-12)

| # | Decision | Choice | Why |
|---|---|---|---|
| 1 | Primary goal | RAM reclaim **and** auto-wake | Memory-bound cluster; parking is already the operating habit |
| 2 | Scope v1 | HTTP services behind Traefik, **incl. GPU HTTP apps**. OUT: DBs/StatefulSets, queue/cron workers (servarr, paperless, n8n, changedetection), critical path, TCP services | Only request-driven workloads can be woken by a request; workers' value is background work that sleeping silently kills |
| 3 | Wake UX | **Hold the request** (Sablier *blocking* strategy) everywhere; no waiting page | One mental model, API-safe. Cloudflare-proxied hosts cap held requests at ~100s — slow boots may 524 once; the wake continues and a retry lands |
| 4 | Engine | **Sablier v1.15+, plugin vendored as a Traefik *local* plugin, pinned, `failOpen: true`** | Only option with a real probe-exclusion story; one small pod; groups; maintained (Jul 2026). Yaegi risk bounded — see Failure modes |
| 5 | Idle timeout | `sessionDuration: 3h` default, per-service override | Lazy by choice: candidates are weekly/monthly-use, 15m-vs-3h RAM delta is negligible, cold-start annoyance isn't. GPU tenants *should* override shorter (30m–1h) — T4 VRAM is scarcer than RAM |
| 6 | Monitoring semantics | Probes excluded via `ignoreUserAgent` → enrolled monitors go **shallow** (green = ingress + wake layer up). Add one wake-failure alert | Monitors must not keep services awake. Real failure mode ("woke but never became ready") caught by kube-state metrics |
| 7 | Pilot | **resume + netbox + whisper**, 1 week | Static sanity / heavy slow-boot Authentik-gated browser app / GPU API service. All three already parked — enrolling changes nothing until first visit |

## Options considered (July 2026 survey)

Full survey in the session research; summary:

| Option | Verdict |
|---|---|
| **Sablier v1.15.0** (chosen) | Purpose-built, active, 1 pod, blocking+dynamic strategies, `ignoreUserAgent` probe exclusion, groups, idle-memory scaling, calendar hours. Risk: Yaegi Traefik plugin (see mitigations) |
| **Elasti v0.1.25** | Elegant (proxy in path only at zero, PromQL triggers) but pre-1.0, and **no probe exclusion** — every monitored service wake-flaps unless monitors are reworked |
| **KEDA + http-add-on v0.15** | Still beta, breaking releases; permanent fail-closed interceptor tier (~8 pods); **no probe exclusion** |
| **Knative Serving** | Requires rewriting every Deployment as a Knative Service + own networking layer; Traefik support experimental. Overkill |
| **Snorlax** | Dormant since 2025-01; rewrites Ingress objects → Terraform drift every sleep/wake cycle |
| **kube-green** | Calendar-only (no wake-on-request); Sablier's `running-hours` labels cover the same ground. Skip |
| **Generalize gate.py** | Custom controller we maintain forever; "reuse before building" says adopt OSS first. gate.tf stays as the proof the pattern works here |

## Architecture

```mermaid
flowchart LR
    subgraph edge [Edge]
        CF[Cloudflare / direct LB]
    end
    subgraph traefik [Traefik x3 — stock chart]
        MW[middleware chain\nretry → rate-limit → csp → auth]
        SP[sablier plugin\nVENDORED LOCAL, pinned, failOpen]
    end
    SA[Sablier deployment\nstacks/sablier — 1 pod]
    K8S[(K8s API)]
    subgraph enrolled [Enrolled service]
        D[Deployment replicas 0↔1\nlabels: sablier.enable, sablier.group]
        SVC[Service]
    end
    PROM[Prometheus\nwake-fail alert]

    CF --> MW --> SP
    SP -- "session status?" --> SA
    SA -- "scale 0→1, watch ready" --> K8S
    K8S --> D
    SP -- "forward when ready" --> SVC --> D
    SA -. session metrics .-> PROM
    K8S -. kube-state: desired>0 & unavailable .-> PROM
```

Wake and probe paths:

```mermaid
sequenceDiagram
    participant C as Client (browser/API)
    participant M as Uptime Kuma / blackbox
    participant T as Traefik (auth middlewares first)
    participant P as sablier plugin (blocking)
    participant S as Sablier API
    participant K as K8s API
    participant A as App pod

    Note over M,P: Probe path — never wakes the app
    M->>T: GET / (UA: Uptime-Kuma)
    T->>P: after auth chain
    P-->>M: 200 immediately (ignoreUserAgent match,<br/>no wake, no session refresh)

    Note over C,A: First real request — held until ready
    C->>T: GET / (real UA, authed)
    T->>P: after auth chain
    P->>S: session for group "netbox"?
    S->>K: scale Deployment 0→1
    K->>A: schedule + start
    S-->>P: ready (session opened, 3h)
    P->>A: forward original request
    A-->>C: real response (cold start = boot time)

    Note over S,K: No requests for sessionDuration (3h)
    S->>K: scale Deployment → 0 (parked)
```

Key properties:

- **The sablier middleware sits AFTER the auth middleware** — unauthenticated
  scanners/bots bounce at Authentik/Anubis without ever waking an app. The
  `ingress_factory` chain already appends extras after `local.auth_middleware`,
  so the ordering falls out of the existing module.
- **Warm path cost:** one in-process plugin check per request (no extra network
  hop; Sablier API is only consulted per session semantics). No second proxy
  tier, unlike KEDA's interceptor.
- **Sessions live in Sablier's memory** — a Sablier pod restart forgets
  sessions; enrolled apps just get a fresh 3h window (benign; no persistence
  needed for v1).

## Implementation

### New stack: `stacks/sablier/`

- `helm_release` from the official `sablierapp` chart (Terraform-native), 1
  replica, tier-appropriate resources (small Go binary; ~64–128Mi).
- Kubernetes provider enabled; RBAC scoped to get/list/watch/update/patch on
  `deployments` (+ statefulsets off for v1) — mirror the least-privilege shape
  of the android-emulator gate Role.
- Prometheus scrape annotations (v1.15 exports session/expiry metrics).

### Traefik changes (`stacks/traefik/`)

1. **Vendor the plugin as a LOCAL plugin** — `sablier-traefik-plugin` pinned
   (v1.3.x), source mounted into the Traefik pods at
   `/plugins-local/src/github.com/sablierapp/sablier-traefik-plugin` via a
   ConfigMap (plugin is a handful of Go files; if it outgrows the 1MiB
   ConfigMap limit, fall back to a GHA-baked Traefik image per the infra-owned
   images pattern). Local plugins never touch `plugins.traefik.io` — immune to
   the traefik#13005 startup-revalidation failure class.
2. **`allowEmptyServices: true`** on the `kubernetesIngress` (and CRD)
   provider so routers to 0-endpoint Services stay registered instead of
   dropping out.
3. No other Traefik config changes; stock chart stays.

### Enrollment surface (per service)

One first-class knob on `ingress_factory` + labels on the Deployment:

```hcl
# ingress_factory — new optional object variable
sablier = {
  group            = "netbox"     # defaults to var.name
  session_duration = "3h"         # default; override per service
}
```

- The module emits the namespace-scoped `Middleware` CR
  (`${namespace}-sablier-${name}@kubernetescrd`, blocking strategy,
  `failOpen: true`, shared `ignoreUserAgent` regex list) and appends it to the
  router chain after auth — same pattern as the existing `custom-csp` /
  `buffering` per-ingress middlewares.
- The Deployment gets `sablier.enable: "true"` + `sablier.group: <group>`
  labels, and `replicas` joins the `lifecycle.ignore_changes` list with a
  greppable marker comment `# SABLIER_MANAGED_REPLICAS` (same convention as
  `# KYVERNO_LIFECYCLE_V1`) so `terragrunt apply` and the daily drift job
  never fight the scaler.
- Multi-deployment apps share one `sablier.group` (e.g. `postiz` =
  postiz + temporal + elasticsearch — one visit wakes the chain, one expiry
  parks all three).

### Enrollment checklist (every service, every wave)

1. Request-driven only — no background jobs/queues/watchers that sleeping
   would silently kill (excludes calibre-web-automated's folder ingest, n8n
   crons, servarr).
2. **No WebSocket dependence** — open WS frames don't refresh Sablier sessions
   (upstream sablier-traefik-plugin #26); WS-heavy apps stay out until fixed.
3. Uptime Kuma monitor is **status-only** — a keyword monitor would sit
   permanently red against the probe-path 200. Switch or drop it.
4. Boot time ≤ ~100s if the hostname is Cloudflare-proxied (524 on first hit
   otherwise — tolerable but note it), no limit for `internal`/non-proxied.
5. GPU tenants: declare `viktorbarzin.me/gpumem` and confirm T4 budget
   headroom first (see below), and set a shorter `session_duration`.

### Monitoring

- **Shared `ignoreUserAgent` list** (one place, the middleware template):
  `Uptime-?Kuma.*`, `Blackbox.*`, `Go-http-client.*` (blackbox default).
  Probes get an immediate 200 and never wake or refresh anything.
- **Enrolled monitors are shallow by design**: green = edge + Traefik +
  Sablier alive. Accepted trade-off (decision #6).
- **New alert `SablierWakeFailed`** (monitoring stack): an enrolled deployment
  (`sablier.enable=true` via kube-state labels) with desired replicas > 0 and
  unavailable replicas > 0 for 5m — "someone knocked, it tried to wake, it
  couldn't". This is the deep health signal, fired exactly when it matters.
- Sablier session metrics land in Prometheus for a Grafana panel (sessions
  active / expiries / wakes per service) — nice-to-have, wave 2.

### GPU interplay (ADR-0016)

Verified 2026-07-12: **whisper declares no `viktorbarzin.me/gpumem` and no
`nvidia.com/gpu`** — only a nodeSelector + toleration. It therefore schedules
onto node1 outside the VRAM budget accounting (the 2026-07-07 collision
class). The pilot enrolls whisper **as-is**: waking it recreates exactly
today's manual-wake risk profile, no worse. **chatterbox-tts is already
scale-0↔1 managed by the GPU demand-gate** (`stacks/tts` VRAM-admission
CronJobs) — it must NOT also enroll in Sablier (two controllers fighting over
`replicas`); at wave 2 decide migrate-or-keep per workload, never both. Wave 2
GPU enrollment (ebook2audiobook, and chatterbox-tts only if migrated off the
demand-gate) is **gated on the ADR-0016 budget retune**
(declared budgets already sum to 13300/14000 MiB; there is no headroom to
declare honest budgets for wake-on-demand tenants until llama-swap/immich-ml
are retuned). 3h sessions on GPU tenants hold VRAM long after use — override
to 30m–1h at enrollment.

## Failure modes

| Failure | Behavior | Mitigation |
|---|---|---|
| Sablier pod down | `failOpen: true` → running apps unaffected (plugin passes through); **sleeping apps 503** until Sablier returns | Accepted: strictly better than today (parked apps are already "503" until a human scales them). Alert on Sablier deployment down |
| Yaegi plugin regression on a Traefik upgrade (the crowdsec-plugin history) | Plugin fails to load → Traefik logs errors; local plugin load failure can block router config referencing it | Vendored + **pinned** — a Traefik chart bump never changes the plugin; re-validate the plugin explicitly on every Traefik upgrade (add to the upgrade runbook). Open upstream issue #44 (intermittent bypass on k8s+v3) — watch; failOpen means bypass degrades to "no scale-to-zero", not an outage |
| plugins.traefik.io outage at Traefik startup (traefik#13005) | N/A — local plugins skip the registry entirely | The reason for vendoring |
| Session lost mid-use (WS blindspot, >3h form think-time) | App parks; next request wakes it. Data loss possible on un-submitted forms | 3h lazy default chosen for this; WS apps excluded by checklist |
| Cold start > client timeout (CF ~100s) | First request 524s; wake already triggered; retry lands | Documented per-service in checklist item 4 |
| Sablier scales down a service mid-deploy | Sablier only manages enrolled groups; deploys bump generation and Sablier wake targets the recorded replica count | Keep enrolled services at recorded `replicas=1`; verify during pilot |

## Rollout

- **Wave 0 — platform (no behavior change):** `stacks/sablier/` + Traefik
  local-plugin vendoring + `allowEmptyServices` + the `ingress_factory`
  `sablier` variable + `SablierWakeFailed` alert. Zero services enrolled;
  verify Traefik rolls cleanly across all 3 replicas with the plugin loaded.
- **Wave 1 — pilot (1 week):** enroll **resume** (static sanity), **netbox**
  (heavy, slow boot, Authentik-gated, form-heavy), **whisper** (GPU, API
  clients, blocking mode). All currently parked → enrolling is a no-op until
  first visit. Success criteria: probes stay green without wakes (Sablier
  metrics show zero probe-triggered sessions); first request wakes within
  boot-time; sessions expire → replicas back to 0; no plugin errors across a
  `rollout restart` of Traefik; no drift-detection noise on `replicas`.
- **Wave 2 — the parked set + groups:** remaining hand-parked services
  passing the checklist (postiz **group** incl. its always-running
  elasticsearch, grampsweb, dashy, osm-routing trio, openlobster, t3-afk…),
  GPU tenants **after the ADR-0016 budget retune**. The android-emulator gate
  stays as-is (its idle signal is `dumpsys power` via exec, not HTTP —
  Sablier can't replicate it); consolidation is a someday-maybe.
- **Wave 3 — data-driven extension:** lowest-traffic *running* services from
  `traefik_service_requests_total` (7d rates, 2026-07-12 snapshot): trek and
  health (0 req/7d), wealthfolio, drone-logbook, beadboard, freedify×2,
  learn, excalidraw, privatebin, cyberchef, jsoncrack, speedtest,
  stirling-pdf, city-guesser, networking-toolbox — each through the
  checklist individually. Expected reclaim: order of 5–10Gi across waves 2–3.

## Out of scope (v1)

TCP services (torrserver, coturn, mail), queue/cron workers, StatefulSets/DBs,
the waiting-page (dynamic) strategy, kube-green/calendar scheduling, Sablier's
idle-memory scaling (interesting for a later iteration), migrating the
android-emulator gate.
