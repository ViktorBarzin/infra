# Post-Mortem: Authentik Embedded Outpost `/dev/shm` Fills — Cluster-Wide Auth Blocked

| Field | Value |
|-------|-------|
| **Date** | 2026-04-18 |
| **Duration** | ~44h for first-affected user (Emil, Apr 16 17:00 → Apr 18 12:40 UTC); ~30min for cluster-wide impact (Apr 18 12:10 → 12:40 UTC) |
| **Severity** | SEV2 — authentication blocked for all users on all Authentik-protected services |
| **Affected Services** | ~30+ Authentik-protected subdomains (every service using the `authentik-forward-auth` Traefik middleware) |
| **Status** | Root cause fixed; permanent mitigation applied; alerting still TODO |

## Summary

The `ak-outpost-authentik-embedded-outpost` pod's `/dev/shm` (default 64 MB tmpfs) filled to 100% with ~44,000 `session_*` files. Once full, every forward-auth request failed to write its session state with `ENOSPC` and the outpost returned HTTP 400 instead of the usual 302 → login redirect. All users on all protected services were unable to log in.

Detection was delayed because the initial user report (Emil) looked like a per-user bug — investigation spent two days chasing hypotheses about non-ASCII headers, user privileges, cookie corruption, and a newly-deployed Cloudflare Worker before the real cause was found in the outpost logs.

## Impact

- **User-facing**: HTTP 400 on initial GET of any Authentik-protected site (`terminal`, `grafana`, `immich`, `proxmox`, `london`, etc.). Existing sessions whose cookies were still cached worked until their cookie rotation attempt, then broke.
- **Blast radius**: Every service using the `authentik-forward-auth` middleware via the "Domain wide catch all" Proxy provider. Public and internal.
- **Duration**: First user (Emil) broken since 2026-04-16 ~17:00 UTC after his last valid session. Cluster-wide block when Viktor's cached session stopped being sufficient — roughly 2026-04-18 12:10 UTC. Fixed 12:40 UTC.
- **Data loss**: None. Session state in tmpfs is ephemeral by design.
- **Monitoring gap**: No Prometheus alert on outpost `/dev/shm` usage. No alert on outpost 400 response rate. Uptime Kuma external monitors hitting protected services returned 400s for 40+ hours without paging.

## Timeline (UTC)

| Time | Event |
|------|-------|
| **Apr 15 ~09:21** | `ak-outpost-authentik-embedded-outpost-587598dc4b-fvzzz` pod started (normal rolling restart, unrelated to this incident). `/dev/shm` fresh. |
| **Apr 16 16:23:32** | Emil's last successful `authorize_application` event from his iPhone Brave (`85.255.235.23`). After this point, his subsequent requests create session files — his new sessions work briefly, then `/dev/shm` fills and every new session write fails. |
| **Apr 16 ~17:00 (approx)** | `/dev/shm` at ~44,000 files = 100% full. New forward-auth requests start returning 400 across the board. Viktor's browser still has a valid cached cookie so his requests succeed without writing new session files. |
| **Apr 17 10:30 (approx)** | Emil reports "terminal.viktorbarzin.me returns 400" to Viktor. |
| **Apr 18 09:00–12:30** | Deep investigation begins. Multiple hypotheses tested and rejected: non-ASCII bytes in Emil's `name` field, policy denial, cookie corruption, Rybbit Cloudflare Worker (deployed 2026-04-17 — suspicious timing, turned out unrelated), plaintext redirect scheme. |
| **Apr 18 12:20:39** | First direct evidence found: 2 Chrome 400s in Traefik logs from Emil's IP `176.12.22.76` (BG) on `terminal.viktorbarzin.me`, request missing `authentik_proxy_*` cookie. Redirect loop observed on iPhone IPv6 `2620:10d:c092:500::7:8c0d`. |
| **Apr 18 12:34** | Viktor reports he can no longer log in either. |
| **Apr 18 12:38** | `curl` against direct Traefik (`--resolve` bypassing Cloudflare) returns the same 400 with Authentik's CSP header — Cloudflare Worker exonerated. |
| **Apr 18 12:39** | Outpost log grep finds the smoking gun: `failed to save session: write /dev/shm/session_XXX: no space left on device`. |
| **Apr 18 12:40:13** | `kubectl delete pod ak-outpost-authentik-embedded-outpost-587598dc4b-fvzzz` — tmpfs cleared on pod restart. Replacement pod `-8qscr` Running within 8s. Cluster unblocked. |
| **Apr 18 12:41** | Verified: direct-Traefik and via-CF curls both return `HTTP 302` to Authentik auth flow. Viktor authenticates successfully on `proxmox.viktorbarzin.me`. |
| **Apr 18 12:53** | Permanent fix applied via Authentik API: `PATCH /api/v3/outposts/instances/{uuid}/` setting `config.kubernetes_json_patches` to mount `emptyDir {medium: Memory, sizeLimit: 512Mi}` at `/dev/shm`. |
| **Apr 18 12:54** | Authentik controller reconciled the Deployment within 5s. `kubectl rollout restart` triggered new pod `-k5hv8`. `/dev/shm` now `tmpfs 256M` (4× the previous capacity; K8s clamps the tmpfs size to pod memory policy, but usage is capped at `sizeLimit=512Mi`). Forward-auth verified working. |

## Root Cause Chain

```
[1] goauthentik/proxy outpost uses gorilla/sessions FileStore
 └─> each forward-auth request that has no valid session cookie writes
     /dev/shm/session_<random> (~1500 bytes/file)
         │
         ├─> [2] Catch-all Proxy provider's access_token_validity = hours=168 (7 days)
         │    └─> each file's MaxAge = 7 days
         │        └─> Upstream 5-min GC (PR #15798, shipped in ≥ 2025.10) can only
         │            delete files whose MaxAge has EXPIRED, not whose age exceeds any
         │            shorter threshold
         │
         ├─> [3] Measured creation rate: ~18 files/min (Uptime-Kuma monitors +
         │    real user traffic)
         │    └─> 18/min × 60 × 24 × 7 = 181,440 steady-state files expected
         │
         └─> [4] Pod's /dev/shm default: 64 MB tmpfs (Kubernetes default)
              └─> 64 MB / 1500 bytes ≈ 44,000 files maximum
                  └─> Full in approx 44,000 / (18 × 60) min ≈ 41 hours
                      └─> Actual observed time: pod started Apr 15 ~09:21,
                          first ENOSPC ~Apr 16 ~17:00 ≈ 32 hours
                          (some excess from Uptime-Kuma bursts)

[ENOSPC] -> every new forward-auth request fails -> outpost returns HTTP 400
         -> Traefik forwards the 400 to the browser
         -> user sees "400 Bad Request" on every protected site
```

## Why Diagnosis Took So Long

The initial report was framed as "Emil can't access terminal" — a per-user symptom. All four pre-registered hypotheses in the triage plan (non-ASCII bytes in header value, oversized cookie, corrupt user attribute, provider policy rejecting groups) were per-user explanations, all of which turned out to be falsified.

Contributing distractions:
1. **Misattribution in initial research** — an `authorize_application` event for Viktor (`vbarzin@gmail.com`) at 2026-04-18 08:09 was initially attributed to Emil. This led to the incorrect conclusion that Emil was authenticating successfully today.
2. **Rybbit analytics Cloudflare Worker deployed 2026-04-17** (see memory #792, commit around 2026-04-17 21:26 UTC) ran on `*.viktorbarzin.me/*`. Suspicious timing — Viktor's first instinct was "this must be the Worker." The Worker WAS adding long cookies to browser state, but not the cause of the 400. Exonerated by direct-Traefik curl returning the same 400.
3. **Viktor's cached session masked the outage** — only unauthenticated requests wrote new session files. Viktor's valid cookie kept working until the outpost needed to rotate state, at which point he also hit 400.
4. **The tell is in the outpost logs, not anywhere else.** `grep 'no space left on device'` on the outpost logs would have found it in seconds, but the investigation scope started with user records, then cookies, then the Worker — outpost logs weren't grepped until hour 3+.

## Contributing Factors

1. **No alert on outpost `/dev/shm` usage.** A simple `kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes > 0.8` or equivalent cAdvisor metric would have paged hours before users noticed.
2. **No alert on outpost HTTP 400 rate.** `increase(authentik_outpost_http_requests_total{status="400"}[15m])` went from ~0 to thousands — invisible to our monitoring.
3. **No alert on "Uptime-Kuma external monitors all turning red simultaneously."** Every external monitor for a protected service started failing, but each is individually monitored — correlated failures across dozens of services didn't trigger a higher-level alert.
4. **Default Kubernetes `/dev/shm` is 64 MB.** This is fine for most workloads, but the goauthentik proxy outpost writes one session file per unauthenticated request with a 7-day retention. The default sizing is an accident waiting to happen on any busy deployment.
5. **Upstream issue [#20093](https://github.com/goauthentik/authentik/issues/20093)** ("External Proxy Outpost cannot use persistent session backend") is still OPEN as of 2026-04-18. Known architectural limitation.
6. **Catch-all Proxy provider is UI-managed, not Terraform-managed.** Its `access_token_validity` and the outpost's `kubernetes_json_patches` are configured in Authentik's PostgreSQL database, not in code. This means the fix applied today is invisible to `git log` and vulnerable to drift if someone changes it in the UI.

## Detection Gaps

| Gap | Impact | Fix |
|-----|--------|-----|
| No alert on outpost `/dev/shm` usage | Outage progressed from "Emil only" to "everyone" over 40+ hours silently | Add Prometheus alert: `kubelet_volume_stats_used_bytes{namespace="authentik",persistentvolumeclaim=~"dshm.*"} / kubelet_volume_stats_capacity_bytes > 0.8` (or per-container cAdvisor metric if emptyDir not a PVC) |
| No alert on outpost 400 rate spike | ~thousands of 400s over 40h didn't page | Alert on `increase(traefik_service_requests_total{code="400",service=~".*viktorbarzin-me.*"}[15m]) > N` OR on outpost-specific 400 metric |
| Uptime Kuma external monitors not cross-correlated | Dozens of red monitors didn't trigger a cluster-wide alert | Add meta-alert: "more than N [External] Uptime Kuma monitors down within 10 min" — strong signal of shared-infra failure |
| Outpost logs not searched during initial triage | Investigation went down 4 wrong paths before finding the real error | Runbook addition: for any Authentik forward-auth issue, FIRST command is `kubectl -n authentik logs -l goauthentik.io/outpost-name=authentik-embedded-outpost --since=1h \| grep -iE 'error\|no space'` |

## Prevention Plan

### P0 — Prevent this exact failure

| Priority | Action | Type | Details | Status |
|----------|--------|------|---------|--------|
| P0 | Size `/dev/shm` up via `kubernetes_json_patches` on the embedded outpost config | Config | `PATCH /api/v3/outposts/instances/0eecac07-97c7-443c-8925-05f2f4fe3e47/` with `config.kubernetes_json_patches.deployment` adding an `emptyDir {medium: Memory, sizeLimit: 512Mi}` volume at `/dev/shm`. Authentik reconciles the Deployment within 5 minutes. **Applied 2026-04-18 12:53 UTC.** | **DONE** |

### P1 — Detect this next time

| Priority | Action | Type | Details | Status |
|----------|--------|------|---------|--------|
| P1 | Prometheus alerts on outpost `/dev/shm` fill (two thresholds) | Alert | Group `Authentik Outpost` added in `stacks/monitoring/modules/monitoring/prometheus_chart_values.tpl`. `AuthentikOutpostMemoryHigh` (warning, working set > 1.5 GiB for 15m) + `AuthentikOutpostMemoryCritical` (critical, > 1.8 GiB for 5m) + `AuthentikOutpostRestarts` (warning, > 2 restarts in 30m). Applied 2026-04-18 13:16 UTC; loaded in Prometheus, state=inactive. | **DONE** |
| P1 | Uptime-Kuma meta-monitor: "N+ external monitors down simultaneously" | Alert | Either a Prometheus rule over `uptime_kuma_monitor_status == 0` counts, or a dedicated external probe. Very strong signal of shared-infra failure. | TODO |
| P1 | Bump tmpfs `sizeLimit` from 512Mi → 2Gi + set explicit container memory limit 2560Mi | Config | Patched outpost `kubernetes_json_patches` via Authentik API. 2026-04-18 13:06 UTC (sizeLimit), 13:22 UTC (container limit). **Gotcha**: `sizeLimit` alone is insufficient — writes to tmpfs count against container cgroup memory, and Kyverno's `tier-defaults` LimitRange sets a default `limits.memory: 256Mi` which OOM-kills the container before tmpfs fills. Fix is to also set `containers[0].resources.limits.memory` ≥ `sizeLimit + working_set_headroom`. Verified 1.5 GB file write succeeds on the configured pod; df reports 2.0 GB tmpfs. Gives ~8× growth headroom at current probe rate. | **DONE** |

### P2 — Codify the fix so it survives drift

| Priority | Action | Type | Details | Status |
|----------|--------|------|---------|--------|
| P2 | Codify the catch-all Proxy provider + embedded outpost config in Terraform | Architecture | Adopt `goauthentik/authentik` Terraform provider in `infra/stacks/authentik/`. Import the existing UUID `0eecac07-97c7-443c-8925-05f2f4fe3e47` and the catch-all provider pk=5. Move `kubernetes_json_patches` into TF so the fix is reviewable in git. | TODO |
| P2 | Runbook: Authentik forward-auth troubleshooting | Docs | Add a runbook at `docs/runbooks/authentik-forward-auth-400.md` with the "grep outpost logs first" first step, plus pointer commands for `/dev/shm` usage, session file count, and recent authorize events. | TODO |

### P3 — Upstream + architectural

| Priority | Action | Type | Details | Status |
|----------|--------|------|---------|--------|
| P3 | Comment/support on authentik issue [#20093](https://github.com/goauthentik/authentik/issues/20093) | Upstream | Request either a persistent-backed session store (Redis/DB) OR a configurable GC interval shorter than the default 5 min. | TODO |
| P3 | Consider shortening `access_token_validity` from 168h (7 days) to 24h | Config | Reduces steady-state session file count from ~181k to ~26k (7× reduction). Trade-off: users re-auth daily. Viktor's call on UX tolerance. | TODO |
| P3 | Evaluate moving forward-auth away from the embedded outpost | Architecture | The embedded outpost is a single replica Go binary with in-memory session state. An external, multi-replica outpost with Redis-backed sessions is the production-grade deployment. Probably overkill for a home-lab, but worth noting. | TODO (paused) |

## Lessons Learned

1. **When a per-user bug affects a shared infrastructure layer, suspect the shared layer, not the user.** The framing "Emil gets 400" led the first two hours of investigation down four user-specific rabbit holes. A sanity check ("does ANY user's non-cached request to a protected site return 400?") would have cut to the chase in minutes.

2. **Check the outpost logs first, not last.** For any Authentik forward-auth oddity, the first `kubectl logs` should be on the outpost pod, grepping for `error` and `ENOSPC`. The outpost is the component that actually makes the 400/302 decision.

3. **Cache + low-request users mask outages longer than you'd think.** Viktor had a valid cookie and his browser kept using it without writing new session files; he couldn't reproduce the bug Emil saw. The outage felt per-user until his cookie rotation needed to write state. **Any outage that "only affects some users" needs an active check from a fresh, cookie-less context** — `curl` with no cookie jar is the fastest way.

4. **Default tmpfs sizing + per-request file writes = ticking clock.** 64 MB of `/dev/shm` is a Kubernetes default, not a considered choice. Any workload that writes per-request files into tmpfs without aggressive GC will eventually fill, and the time-to-fill scales inversely with request rate. Worth auditing other services that might have the same pattern.

5. **UI-managed Authentik config is invisible to git review.** Our catch-all Proxy provider, embedded outpost config, property mappings, and policy bindings are all in Authentik's PostgreSQL database. The fix applied today (`kubernetes_json_patches`) is durable but not discoverable from `git log`. Drift risk. Codify in Terraform.

6. **Recently-deployed things are prime suspects but not always guilty.** The Rybbit Cloudflare Worker was deployed 2026-04-17 with a wildcard route. Viktor's intuition was "that's the recent change, must be the cause." It was a plausible theory and worth checking — but `curl --resolve` to bypass Cloudflare proved it innocent within 30 seconds. Always have a way to bypass the suspect layer cheaply.

## References

- Memory #836-841: incident details stored in claude-memory MCP (2026-04-18 12:42 UTC).
- Upstream issue: [goauthentik/authentik#20093](https://github.com/goauthentik/authentik/issues/20093) (open).
- Related upstream fix: [PR #15798](https://github.com/goauthentik/authentik/pull/15798) — 5-min session GC shipped in ≥ 2025.10 (our version 2026.2.2 has it, but insufficient alone).
- Beads task: `code-zru` (P1 bug).
