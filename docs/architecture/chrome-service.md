# chrome-service — In-cluster headed Chromium with persistent profile

## Overview

`chrome-service` is a single-replica, persistent-profile, headed
Chromium browser exposed over the Chrome DevTools Protocol (CDP). It
serves two distinct populations:

1. **In-cluster automation callers** — connect via
   `chromium.connect_over_cdp("http://chrome-service.chrome-service.svc:9222")`
   to drive a real browser when upstream anti-bot trips a headless one
   (`disable-devtool.js` redirect-to-google trap, `navigator.webdriver`
   checks, console-clear timing tricks). Currently-active in-cluster
   callers: the `chrome-service-snapshot-harvester` CronJob, and
   **tripit's `PlaywrightFareProvider`** (since 2026-06-11, tripit issue
   #18 / ADR-0007) — the flight-fare scrape connects per quote, opens a
   fresh incognito context, scrapes Google Flights, and closes the
   context; rate-limited to one attempt per 30s with a 6h fare cache, so
   browser load is negligible. The
   `stacks/f1-stream/files/backend/playback_verifier.py` +
   `chrome_browser.py` tree is a vestigial design — the deployed
   f1-stream image (built from `github.com/ViktorBarzin/f1-stream`)
   does not use this code path.
2. **External dev-box Claude Code sessions** — pull an hourly snapshot
   of cookies + localStorage from `chrome.viktorbarzin.me/api/snapshot`
   (bearer-gated) and seed local `@playwright/mcp` instances in
   `--isolated --storage-state=…` mode. This is how concurrent Claude
   Code sessions get their own isolated browser contexts without losing
   shared cookies for logged-in sites.

## Why a separate stack

In-process Chromium inside `f1-stream`:

- Runs **headless** by default (no `Xvfb`/`DISPLAY`).
- Has the `HeadlessChromium/...` UA suffix and `navigator.webdriver === true`.
- Trips `disable-devtool.js`'s **Performance** detector — Playwright's CDP
  adds latency to `console.log(largeArray)` vs `console.table(largeArray)`,
  which the lib reads as "DevTools is open" and redirects to
  `https://www.google.com/`.

`chrome-service` solves this by:

1. Running **headed** under `Xvfb :99` (chromium with `DISPLAY=:99`,
   not `--headless`).
2. Living in a long-lived pod so JIT browser launch latency disappears.
3. Allowing a per-context init script
   (`stacks/chrome-service/files/stealth.js` ~ 40 lines, vendored from
   `puppeteer-extra-plugin-stealth`) to spoof `webdriver`, `chrome.runtime`,
   `plugins`, `languages`, `Permissions.query`, WebGL renderer strings, and
   to hide the `disable-devtool-auto` script-tag attribute so the lib's
   IIFE exits early.

## Wire protocol — CDP (current, since 2026-06-04)

```text
                  http://chrome-service.chrome-service.svc.cluster.local:9222
                                            │
            ┌───────────────────────────────┼───────────────────────────────┐
            │ caller pod                    │                  chrome-service pod
            │  (e.g. f1-stream)             │                  (single replica)
            │                               │
            │  CHROME_CDP_URL ──────────────┘
            │
            │  await chromium.connect_over_cdp(cdp_url)
            │  context = await browser.new_context()   ← incognito (no cookies)
            │      OR: context = browser.contexts[0]   ← persistent (shared cookies)
            │  await context.add_init_script(STEALTH_JS)
            │  page.goto("https://upstream.com/embed/...")
            │
            └─── ←── pages render under Xvfb, headed Chromium ──── ─────────┘
```

### Wire protocol — WS (legacy, removed 2026-06-04)

The previous design used `playwright launch-server --browser chromium`
with a path-token (`ws://...:3000/<TOKEN>`). Callers used
`chromium.connect(ws_url)`. **Problem**: `launch-server` creates
ephemeral browser contexts per `connect()` call, so cookies never
persisted to the PVC despite the `/profile` mount. We migrated to
direct chromium launch with `--user-data-dir` + CDP exposed on :9222
so cookies actually live across pod restarts.

## Cookie warming + snapshot pipeline

```text
┌─────────── chrome-service pod ──────────────────────────────────────────┐
│                                                                          │
│  chrome-service container (chromium --user-data-dir=/profile/chromium-data
│                            --remote-debugging-port=9222)                 │
│  ▲                                                                       │
│  │ user logs in via noVNC ← chrome.viktorbarzin.me (Authentik)           │
│  │                                                                       │
│  Cookies + localStorage land in /profile/chromium-data/Default/          │
│                                                                          │
│  snapshot-server sidecar (python stdlib HTTP server, :8088)              │
│  ↑ serves /profile/snapshots/storage-state.json (bearer-gated)           │
└──────────────────────────────────────────────────────────────────────────┘
       ▲
       │ hourly (cron 23 * * * *)
       │
┌──────┴── chrome-service-snapshot-harvester CronJob ─────────────────────┐
│  podAffinity → same node as chrome-service (RWO PVC)                    │
│  python: connect_over_cdp + ctx.storage_state(path=...)                 │
│  writes /profile/snapshots/storage-state.json (atomic rename)           │
└──────────────────────────────────────────────────────────────────────────┘

External caller (dev box):
  systemd timer (hourly) → curl -H "Authorization: Bearer $TOKEN"
                              https://chrome.viktorbarzin.me/api/snapshot
                              -o ~/.cache/playwright-shared-storage-state.json
  @playwright/mcp --isolated --storage-state ~/.cache/...storage-state.json
```

## Image pin

Both the server image (`mcr.microsoft.com/playwright:v1.48.0-noble` in
`stacks/chrome-service/main.tf`) and the Python client
(`playwright==1.48.0` in callers' `requirements.txt`) **must match
minor-versions**. Bump in lockstep — Playwright protocol changes between
minors and the client cannot connect to a mismatched server.

The harvester + snapshot-server sidecar use
`mcr.microsoft.com/playwright/python:v1.48.0-noble` — same playwright
minor, with Python-side bindings pre-installed.

## Storage

- **`chrome-service-profile-encrypted`** (PVC, 2Gi → 10Gi autoresize,
  `proxmox-lvm-encrypted`) — Chromium user-data dir at
  `/profile/chromium-data` + snapshot at `/profile/snapshots/storage-state.json`.
  Encrypted because cookies/localStorage may include third-party auth tokens
  for sites callers drive.
- **`chrome-service-backup-host`** (NFS, RWX) — destination for a 6-hourly
  CronJob that `tar -czf /backup/<YYYY_MM_DD_HH>.tar.gz -C /profile .`,
  retention 30 days.

## Auth + secrets

- Vault KV `secret/chrome-service.api_bearer_token` — 32-byte URL-safe
  random, rotated by hand:
  `vault kv put secret/chrome-service api_bearer_token=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')`.
- ESO syncs into namespace-local Secret `chrome-service-secrets`. The
  `snapshot-server` sidecar reads it via `secret_key_ref`.
- f1-stream still imports the secret (via `chrome-service-client-secrets`)
  for parity, but the CDP endpoint no longer requires it for connection —
  NetworkPolicy is the gate.
- Reloader (`reloader.stakater.com/auto = "true"`) cascades token rotation
  to the snapshot-server sidecar.
- **Dev-box cache**: each dev box keeps a local copy at
  `~/.config/playwright/token` (chmod 600). Re-fetch from Vault after
  rotation: `vault kv get -field=api_bearer_token secret/chrome-service > ~/.config/playwright/token`.

## Network controls

- **`kubernetes_network_policy_v1.ws_ingress`** — three ingress rules:
  - **TCP/9222** (Chromium CDP): only namespaces labelled
    `chrome-service.viktorbarzin.me/client = "true"` (plus an explicit
    fallback for `f1-stream` by `kubernetes.io/metadata.name`, plus
    `chrome-service`'s own namespace for the harvester CronJob).
  - **TCP/6080** (noVNC HTTP+WS): only the `traefik` namespace.
  - **TCP/8088** (snapshot-server): only the `traefik` namespace
    (bearer-token check happens in `snapshot_server.py`).
- **CDP port 9222** is internal-only (no ingress, no Cloudflare DNS).
- **noVNC sidecar** (`forgejo.viktorbarzin.me/viktor/chrome-service-novnc`)
  exposes a live HTML5 view of the headed Chromium session via
  `x11vnc` (connected to Xvfb on `localhost:6099`) bridged to
  `websockify` on port 6080. Service `chrome` maps :80 → :6080 and is
  exposed via `ingress_factory` at `chrome.viktorbarzin.me`,
  Authentik-gated.
- **snapshot-server sidecar** (`mcr.microsoft.com/playwright/python:v1.48.0-noble`)
  serves `GET /api/snapshot` from `/profile/snapshots/storage-state.json`,
  bearer-gated by `PW_TOKEN`. Service `chrome-snapshot` maps :8088 → :8088
  and is exposed at `chrome.viktorbarzin.me/api/snapshot` via a second
  `ingress_factory` call with `auth = "none"` (the bearer check is in
  the sidecar, not at the ingress layer).

## Adding a new in-cluster caller

See `stacks/chrome-service/README.md` for the recipe (label namespace,
inject `CHROME_CDP_URL`, vendor `stealth.js`).

## Driving from OUTSIDE the cluster (`homelab browser`)

Agents on the devvm reach this browser through the **`homelab browser`** CLI
(`cli/`, ADR-0013) — the packaged, discoverable form of the ad-hoc
`connect_over_cdp` recipe. Use it when a site loads but a gated action
(submit/login) silently fails or hangs — the signature of headless / anti-bot
detection.

```text
devvm:  homelab browser run flow.js
          │  kubectl port-forward svc/chrome-service :9222  (random local port)
          ▼
   http://127.0.0.1:<port>  ──►  chrome-service pod :9222 (CDP)
          │  assert /json/version Browser is "Chrome/…", not "HeadlessChrome"
          │  node + playwright-core@1.48.2 → connectOverCDP
          │  context.addInitScript(stealth.js)   ← same vendored file as in-cluster
          │  run the user's Playwright script with page/context/browser in scope
          └─ port-forward always torn down (success or error)
```

Key facts:

- **port-forward bypasses the `:9222` NetworkPolicy.** It tunnels
  API-server→pod, so the devvm needs no `chrome-service.viktorbarzin.me/client`
  label — unlike in-cluster callers.
- **Client pinned to the image minor.** The node client is
  `playwright-core@1.48.2` (matches `v1.48.0-noble` / Chromium 130), installed
  lazily into `~/.cache/homelab/browser-client/`. Bump it in lockstep when the
  server image bumps (same rule as the in-cluster Python clients — see "Image
  pin" above).
- **Default context is a fresh incognito one** (closed on exit), safe for the
  shared browser; `--shared-context` reuses the warmed persistent profile.
- **`stealth.js` is vendored** into the CLI (`cli/browser_stealth.js`) as a
  byte-identical copy of `files/stealth.js`, guarded by a drift test — so the
  CLI's stealth never diverges from the in-cluster callers'.

## Limits + risks

- **Anti-bot vs stealth arms race** — when an upstream beats us (DRM
  license check, device-fingerprint mismatch, hotlink protection that
  whitelists specific parent domains), the verifier returns
  `is_playable=False` and the extractor moves on. No user-visible
  breakage, just empty stream lists for that source.
- **JWPlayer DRM error 102630** — observed with several hmembeds embeds
  even from the headed chrome-service. The license check bails because
  the request origin isn't on the embed's allowlist; this is upstream
  policy, not an infra defect.
- **Single replica + RWO PVC** — the deployment uses `Recreate` strategy.
  Brief outage on rollout, ~30s for browser warmup.
- **No `/metrics` endpoint** — the cluster's generic
  `KubePodCrashLooping` rule covers basic alerting. A Prometheus scrape
  exporter is day-2 work.
- **Snapshot covers cookies + localStorage only** — Playwright's
  `storage_state()` API doesn't capture IndexedDB or sessionStorage.
  Sites that rely on those for auth won't warm via the snapshot.
- **Snapshot freshness up to 1h stale** — if a site rotates session
  cookies more often than that, an on-demand refresh CLI is needed
  (deferred to follow-on).
