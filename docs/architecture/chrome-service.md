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

## Browser binary — real Google Chrome (for proprietary codecs)

The chrome-service container runs **real Google Chrome**, not the bundled
Chromium, via the infra-owned image `ghcr.io/viktorbarzin/chrome-service-browser`
(`files/chrome/Dockerfile` = `mcr.microsoft.com/playwright:v1.48.0-noble` +
`google-chrome-stable`, built by `.github/workflows/build-chrome-service-browser.yml`).
The launch resolves `CHROMIUM=/opt/google/chrome/chrome`.

**Why:** the Playwright-bundled Chromium has proprietary codecs **compiled out**,
so H.264/AAC video (Instagram Reels, X, most `.mp4`) fails in the noVNC view with
`MEDIA_ERR_SRC_NOT_SUPPORTED` (the bytes download `200 video/mp4` but there's no
decoder — NOT a GPU issue). Royalty-free codecs (VP9/VP8/AV1 → YouTube) always
worked. Swapping `libffmpeg.so` does NOT help (codecs are compiled out, not just
the lib stripped) and Chrome-for-Testing is also codec-less — only
`google-chrome-stable` carries them.

## Image pin

The Playwright base + the Python client (`playwright==1.48.0` in callers'
`requirements.txt`) and the snapshot sidecars
(`mcr.microsoft.com/playwright/python:v1.48.0-noble`) historically had to match
minor-versions. The chrome-service browser is now real Google Chrome (a newer
milestone than the 1.48 Chromium), but the `connect_over_cdp` callers (tripit
fare scrape, `homelab browser`, snapshot-harvester) attach over raw CDP, which is
version-tolerant — verified working against this Chrome. If a future Chrome
milestone breaks a caller, pin Chrome in the Dockerfile or bump the clients.

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
  Authentik-gated. The bare host serves `vnc.html` (image symlinks
  `index.html → vnc.html`); add `?autoconnect=true&resize=scale&path=websockify`
  to skip the Connect button. The view is **black when no browser window is
  open** (idle) — that is normal, not a failed connection. Chrome is launched
  with `--window-size=1280,720 --window-position=0,0` to fill the Xvfb screen
  (no window manager runs, so without it Chrome opens at its profile-persisted
  size and the rest of the framebuffer shows as a black cut-off).

### noVNC fd-sweep gotcha (stuck "Connecting")

If the noVNC client hangs on **"Connecting" forever then times out**, the cause
is almost always x11vnc's fd-table sweep: containerd grants pods
`RLIMIT_NOFILE = 2^31`, and x11vnc `fcntl`-sweeps the **entire** fd table on
every client connection, so the RFB handshake never completes (websockify
accepts the WS and logs `connecting to: localhost:5900`, but x11vnc never sends
the `RFB 003.008` banner). Diagnose: `grep "open files" /proc/$(pgrep -n
x11vnc)/limits` (huge = bad) and time the handshake from a sibling container
(`python3 -c "import socket;s=socket.socket();s.connect(('127.0.0.1',5900));print(s.recv(12))"` —
healthy <0.3s, broken hangs). **Fix: cap `ulimit -n 65536` before x11vnc starts**
— done both in `files/novnc/entrypoint.sh` (root) and via the container `command`
wrapper in `main.tf` (so it applies deterministically even though the image is
`:latest`/`IfNotPresent` and won't re-pull a rebuilt entrypoint). Same bug + fix
as the android-emulator stack.

### noVNC black after a browser-container restart (x11vnc supervision)

A **distinct** failure from the fd-sweep gotcha above: the noVNC client *connects*
but the view is **black**, and the novnc container logs spew
`connecting to: localhost:5900` → `Failed to connect ... [Errno 111] Connection
refused` (x11vnc is **down**, not slow). Cause: `x11vnc` and `websockify` both run
in the **novnc** container, but x11vnc attaches to the **chrome-service** (browser)
container's Xvfb over `localhost:6099` (shared pod network). When the browser
container restarts — Chrome exits cleanly (exit 0, "Completed") or crashes — its
Xvfb vanishes and x11vnc loses its X connection and exits.

`entrypoint.sh` **supervises** x11vnc: it launches x11vnc and websockify as
background children and `wait -n`s on them, exiting non-zero if **either** dies, so
the kubelet restarts the novnc container, which re-waits for Xvfb on `:6099` and
relaunches x11vnc — the bridge **self-heals** across browser-container restarts.
(Before 2026-06-27, x11vnc was an unsupervised background child of an `exec`ed
websockify; a dead x11vnc was never relaunched, leaving `:5900` dead — a
`<defunct>` zombie — and the view black until a manual pod restart. Same
supervision pattern as the android-emulator stack's entrypoint.)

**Diagnose:** `kubectl exec -c novnc -- ps aux | grep x11vnc` (a `<defunct>`/Z
entry = the bug); or the RFB-banner probe from a sibling container (`python3 -c
"import socket;s=socket.socket();s.settimeout(2);s.connect(('127.0.0.1',5900));print(s.recv(12))"`
— healthy returns `b'RFB 003.008\n'`, broken = `ConnectionRefused`). **Immediate
recovery** (no image change): restart just the novnc container with `kubectl exec
-n chrome-service deploy/chrome-service -c novnc -- kill 1` — re-runs its entrypoint
and relaunches x11vnc **without** touching the browser session/in-flight CDP jobs.

> **Deploying a rebuilt novnc entrypoint:** Keel is **off** for this deployment
> (`keel.sh/policy=never`, because the browser container's playwright image is
> version-pinned to f1-stream) and the image is `:latest`/`IfNotPresent`, so a
> rebuilt `:latest` will **not** redeploy on its own. After the
> `build-chrome-service-novnc.yml` GHA build pushes `:latest` + `:<sha>`,
> **SHA-pin** the novnc `image` in `main.tf` to the new `:<sha>` to force the pull
> and rollout (the novnc image is TF-managed — not in the deployment's
> `lifecycle.ignore_changes`).
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
`connect_over_cdp` recipe. It is the **escalation path, not the default**:
agents default to the Playwright MCP / headless browser for all routine
automation, and reach for `homelab browser` ONLY when headless is blocked — a
site loads but a gated action (submit/login) silently fails or hangs, the
signature of headless / anti-bot detection. (Same tiered rule lives in
`~/code/CLAUDE.md` and `homelab browser --help`.)

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

## Multi-user access (sharing the browser)

There is ONE chrome-service browser with ONE persistent profile, warmed with
**Viktor's** logged-in sessions. CDP has no per-context auth, so anyone who can
drive the browser — over the noVNC view OR the CDP/`homelab browser` path — can
reach the persistent profile (`browser.contexts[0]`) and therefore Viktor's
sessions. Access is gated accordingly, per user.

**Decision (2026-06-28):** emo (`emil.barzin` / `emil.barzin@gmail.com`) SHARES
Viktor's browser for form-filling + captcha solving, rather than getting an
isolated instance. The session-exposure trade-off above was explicitly accepted.

Two independent grants make up "browser access" for a user:

1. **noVNC (interactive view, `chrome.viktorbarzin.me`)** — gated by the Authentik
   `admin-services-restriction` policy: the `CHROME_ALLOWED` set
   (`stacks/authentik/admin-services-restriction.tf`) matches the user's Authentik
   username OR email. Add the user there. No kubeconfig/RBAC needed.
2. **CLI (`homelab browser`, CDP over port-forward)** — needs `pods/portforward`
   in `chrome-service` PLUS a non-interactive credential (a normal devvm user's
   kubeconfig is interactive-OIDC-only and can't authenticate a headless agent
   session). Provided by a per-user **ServiceAccount** with a long-lived token
   (`stacks/chrome-service/rbac.tf`, e.g. `emo-browser`): `pods/portforward` in
   this namespace + cluster read-only (`oidc-power-user-readonly`, so it can also
   resolve the Service and doesn't regress the user's normal read). The devvm
   provisioner (`scripts/t3-provision-users.sh` → `install_browser_kubeconfig`)
   reads that token and installs it as the user's DEFAULT kubeconfig context
   (`<user>-browser@homelab`), keeping their personal OIDC login as the
   `oidc@homelab` named context. The SA's existence is the source of truth for who
   gets the CLI — the provisioner no-ops for users without a `<user>-browser` SA.

**To grant another user:** add them to `CHROME_ALLOWED` (noVNC) and/or add a
`<user>-browser` SA + bindings mirroring `emo-browser` in `rbac.tf` (CLI), then run
the provisioner. To revoke: remove from `CHROME_ALLOWED` and delete the SA (rotate
a token by deleting its `<user>-browser-token` Secret).

Because the SA is the user's DEFAULT kubectl credential, other per-namespace
port-forward grants hang off the same identity: `stacks/excalidraw/rbac.tf`
grants `emo-browser` `pods/portforward` in `excalidraw` (2026-07-02) so emo's
agent can upload drawings via the port-forward + `X-Authentik-Username` recipe
in his `~/.claude/CLAUDE.md`. Revoking the SA revokes those too.

## Browser pool (broker + FleetView) — since 2026-07-14

The single master pod above is the **identity browser**; concurrent agent load is
served by an autoscaled **pool** of ephemeral, isolated worker pods. Design +
plan: `docs/plans/2026-07-13-chrome-service-pool-{design,plan}.md`
(published on plans.viktorbarzin.me); spec: GitHub issue ViktorBarzin/infra#79.

```text
  homelab browser run flow.js                 devvm (outside cluster)
        │  1. kubectl port-forward svc/chrome-fleet :8080
        ▼
  chrome-broker (broker.tf) ── POST /acquire {owner,purpose} ─┐
        │  SA chrome-broker: pods create/delete/patch          │
        │  2. create labelled worker Pod (or reuse warm)       │
        │  3. seed = on-demand storage_state() from MASTER ────┼──► chrome-service (master)
        ▼                                                      │
  chrome-worker-<sid>  (bare Pod, activeDeadlineSeconds=3600)  │
        │  app=chrome-worker · CPU 4 / mem 4Gi limit           │
        ▲  4. caller port-forwards pod/<name> :9222 (CDP)      │
        │  5. runs patchright-core script (viewport 1920x1080) │
        └─ 6. POST /release → Pod deleted ─────────────────────┘
```

**Roles.** The master (`chrome-service` Deployment) stays 1 replica: interactive
noVNC login, the persistent profile PVC, the hourly `storage_state()` snapshot,
tripit's fare scrape, and any `--shared-context` write-back work. The **pool** is
separate stateless workers.

**Broker** (`stacks/chrome-service/broker.tf`, `files/broker/broker.py`): a
stdlib-Python service on the stock `playwright/python` image (broker.py +
`worker_pod.json` + `seed_export.py` + `screenshot.py` + FleetView `index.html`
via ConfigMap; pip-installs playwright at startup for the seed/screenshot
**subprocesses** — no custom image, the `gate.py` pattern). Stateless: session
state is reconstructed from pod labels each request (no Redis). k8s via the in-pod
SA token/CA. API: `POST /acquire` {owner,purpose} → {pod,cdpPort,session};
`POST /release` {session}; `GET /sessions`; `GET /seed` (fresh cached
storage_state); `GET /metrics`; `GET /healthz`. SA `chrome-broker` = pods
create/delete/get/list/patch (namespace-scoped; `rbac.tf`).

**Workers.** One session per pod. **Bare burst pods** (broker-created from
`worker_pod.json`): `activeDeadlineSeconds=3600` hard cap, deleted on release/idle
(20m). **Warm pod** (`pool.tf`, `chrome-worker-warm` Deployment, replicas=1):
always-ready standby, claimed by a session-label patch and returned to standby on
release; no activeDeadlineSeconds — a stuck/wedged warm claim is deleted by the
broker reaper (Deployment recreates it). **Selector gotcha:** the warm Deployment
selects on `chrome-pool/role=warm` (NOT `app=chrome-worker`, which the bare burst
pods also carry — else it would adopt+delete them). Both carry `app=chrome-worker`
so the broker's `list_workers` finds warm + bare alike.

**Blast radius (D11).** Each worker has a **CPU limit of 4 cores** — a deliberate
exception to the cluster "no CPU limits" norm, because a single-session ephemeral
browser pegging cores is always a bug (the 6.5h-swiftshader class). Plus the mem
limit + hard deadline + `ChromeWorkerWedged` alert.

**Quota.** The Kyverno tier-4-aux `tier-quota` caps `requests.memory` at 3Gi —
far too small for burst-6. The ns is labelled `resource-governance/custom-quota=true`
(Kyverno then deletes its generated quota) and `broker.tf` defines `chrome-pool`
(requests.memory 16Gi / limits.memory 40Gi / requests.cpu 4 / pods 14) — the
burst ceiling + runaway-create backstop (broker also self-limits to MAX_WORKERS=6).

**Seed model.** Pool sessions derive the master's login **read-only**: the broker
exports cookies+localStorage on-demand via `storage_state()` over CDP (cached
~10s), and `browser_runner.js` injects it into a fresh context. Never written
back. IndexedDB/sessionStorage are not captured — those sites use `--shared-context`
(master). `connect_over_cdp().close()` only disconnects; it never kills the master.

**FleetView** (`chrome-fleet.viktorbarzin.me`, Authentik-gated): a static
dashboard served by the broker — live session table (owner, purpose, current URL
from CDP `/json/list`, age) + best-effort screenshot thumbnails + kill. Prometheus:
`browser_active_sessions{owner}`, `browser_pool_workers{state}`,
`browser_seed_export_seconds/_errors_total`. Alerts (group "Chrome Pool"):
`ChromePoolBrokerDown`, `ChromeWorkerWedged`, `ChromePoolSeedExportFailing`,
`ChromePoolQuotaExhausted`.

**CLI.** `homelab browser` uses the pool by default (acquire → port-forward the
named worker pod → run → release; falls back to the master if the broker is down).
`--shared-context` → master; `--no-seed` → clean context; `--viewport WxH`/`--tall`
→ context viewport (default 1920×1080 DPR1); `homelab browser ls` lists sessions.
CDP client is **patchright-core** (playwright-core drop-in that closes the
`Runtime.enable` anti-bot leak).

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
