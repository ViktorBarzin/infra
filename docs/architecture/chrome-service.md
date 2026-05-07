# chrome-service — In-cluster headed Chromium pool

## Overview

`chrome-service` is a single-replica, persistent-profile, bearer-token-gated
Playwright **launch-server** that exposes a headed Chromium browser over a
WebSocket. Sibling services connect to it instead of running their own
in-process Chromium when the upstream's anti-bot tooling
(`disable-devtool.js` redirect-to-google trap, console-clear timing tricks,
`navigator.webdriver` checks) defeats a headless browser.

Initial caller: `f1-stream`'s `playback_verifier`. Future callers attach
via the WS+token contract documented in `stacks/chrome-service/README.md`.

## Why a separate stack

In-process Chromium inside `f1-stream`:

- Runs **headless** by default (no `Xvfb`/`DISPLAY`).
- Has the `HeadlessChromium/...` UA suffix and `navigator.webdriver === true`.
- Trips `disable-devtool.js`'s **Performance** detector — Playwright's CDP
  adds latency to `console.log(largeArray)` vs `console.table(largeArray)`,
  which the lib reads as "DevTools is open" and redirects to
  `https://www.google.com/`.

`chrome-service` solves this by:

1. Running **headed** under `Xvfb :99` (via `playwright launch-server` with
   a JSON config that pins `headless: false`).
2. Living in a long-lived pod so JIT browser launch latency disappears.
3. Allowing a per-context init script
   (`stacks/chrome-service/files/stealth.js` ~ 40 lines, vendored from
   `puppeteer-extra-plugin-stealth`) to spoof `webdriver`, `chrome.runtime`,
   `plugins`, `languages`, `Permissions.query`, WebGL renderer strings, and
   to hide the `disable-devtool-auto` script-tag attribute so the lib's
   IIFE exits early.

## Wire protocol

```text
                  ws://chrome-service.chrome-service.svc.cluster.local:3000/<TOKEN>
                                            │
            ┌───────────────────────────────┼───────────────────────────────┐
            │ caller pod                    │                  chrome-service pod
            │  (e.g. f1-stream)             │                  (single replica)
            │                               │
            │  CHROME_WS_URL  ──────────────┘
            │  CHROME_WS_TOKEN ─── from `secret/chrome-service.api_bearer_token` (ESO)
            │
            │  await chromium.connect(f"{ws}/{token}")
            │  await ctx.add_init_script(STEALTH_JS)
            │  page.goto("https://upstream.com/embed/...")
            │
            └─── ←── pages render under Xvfb, headed Chromium ──── ─────────┘
```

## Image pin

Both the server image (`mcr.microsoft.com/playwright:v1.48.0-noble` in
`stacks/chrome-service/main.tf`) and the Python client
(`playwright==1.48.0` in callers' `requirements.txt`) **must match
minor-versions**. Bump in lockstep — Playwright protocol changes between
minors and the client cannot connect to a mismatched server.

The Microsoft image ships only the browser binaries, not the `playwright`
npm SDK; the start command runs `npx -y playwright@1.48.0 launch-server`
which downloads the SDK on first start (cached under `$HOME/.npm` via the
PVC) and reuses it on subsequent restarts.

## Storage

- **`chrome-service-profile-encrypted`** (PVC, 2Gi → 10Gi autoresize,
  `proxmox-lvm-encrypted`) — Chromium user-data dir + npm cache.
  Encrypted because cookies/localStorage may include third-party auth tokens
  for sites callers drive. `HOME=/profile` so npx caches there.
- **`chrome-service-backup-host`** (NFS, RWX) — destination for a 6-hourly
  CronJob that `tar -czf /backup/<YYYY_MM_DD_HH>.tar.gz -C /profile .`,
  retention 30 days.

## Auth + secrets

- Vault KV `secret/chrome-service.api_bearer_token` — 32-byte URL-safe
  random, rotated by hand:
  `vault kv put secret/chrome-service api_bearer_token=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')`.
- ESO syncs into namespace-local Secret `chrome-service-secrets`
  (server pod) and `chrome-service-client-secrets` (each caller pod).
- Reloader (`reloader.stakater.com/auto = "true"`) cascades token rotation
  to both server and any annotated caller — no manual rollout.

## Network controls

- **`kubernetes_network_policy_v1.ws_ingress`** — only namespaces labelled
  `chrome-service.viktorbarzin.me/client = "true"` (plus an explicit
  fallback for `f1-stream` by `kubernetes.io/metadata.name`) can reach
  TCP/3000.
- **WS port 3000** is internal-only (no ingress, no Cloudflare DNS).
- **HTTP port 80** (sidecar `nginxinc/nginx-unprivileged:alpine`) serves
  a static health stub at `chrome.viktorbarzin.me`, Authentik-gated.
  Lets a human confirm pod liveness without spinning a browser.

## Adding a new caller

See `stacks/chrome-service/README.md` for the four-step recipe:

1. Label the caller's namespace.
2. Add an `ExternalSecret` pulling `secret/chrome-service`.
3. Inject `CHROME_WS_URL` + `CHROME_WS_TOKEN` env vars.
4. Vendor `stealth.js` and apply via `await context.add_init_script(...)`
   after every `new_context()`.

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
