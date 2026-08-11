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
   browser load is negligible. **`chesscom-streak`** (since 2026-08-08)
   is the third caller and the only one that deliberately attaches to the
   MASTER PERSISTENT PROFILE (`browser.contexts[0]`) rather than opening a
   fresh context: it needs the chess.com session Viktor logged in by hand
   via the live view, and attaching to the master profile lets session-cookie
   rotation persist instead of being discarded with a pool pod. It holds
   the browser for ~20s once a day. The
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

1. Running **headed** under a real X server (neko's Xorg; `Xvfb :99` before
   2026-08-11) rather than `--headless`.
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
            └─── ←── pages render headed under neko's Xorg ─────────────────┘
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
│  neko container (google-chrome --user-data-dir=/profile/chromium-data     
│                  --remote-debugging-port=9223 → cdp-bridge :9222)        │
│  ▲                                                                       │
│  │ user logs in via the neko view ← chrome.viktorbarzin.me (Authentik)   │
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

Both the master and the pool workers run **real Google Chrome**, not the bundled
Chromium — via different images since 2026-08-11:

- **Master:** the stock upstream `ghcr.io/m1k1o/neko/google-chrome` image (see
  "Display — neko WebRTC" below). Chrome at `/usr/bin/google-chrome`.
- **Pool workers:** the infra-owned `ghcr.io/viktorbarzin/chrome-service-browser`
  (`files/chrome/Dockerfile` = `mcr.microsoft.com/playwright:v1.48.0-noble` +
  `google-chrome-stable`, built by
  `.github/workflows/build-chrome-service-browser.yml`). Its launcher resolves
  `CHROMIUM=/opt/google/chrome/chrome`. That image and its workflow stay — the
  neko swap was master-only.

**Why:** the Playwright-bundled Chromium has proprietary codecs **compiled out**,
so H.264/AAC video (Instagram Reels, X, most `.mp4`) fails in the live view with
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

Since 2026-08-11 the master's Chrome milestone comes from the digest-pinned neko
image (`local.neko_image`) rather than from a Dockerfile we control, so a neko
bump also moves Chrome. That is one more reason the pin is a deliberate,
reviewed bump and Keel stays off this deployment.

Callers do not have to sit on 1.48: `chesscom-streak` pins `playwright==1.58.0`
and was verified live against this Chrome/149 browser on 2026-08-08. Because a
`connect_over_cdp` caller never launches a browser itself, it also needs no
browser download — that caller runs on a plain `python:3.12-slim` with
`PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` rather than the Playwright base image.

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
  - **TCP/8080** (neko UI + WS signaling): only the `traefik` namespace.
  - **TCP/8088** (snapshot-server): only the `traefik` namespace
    (bearer-token check happens in `snapshot_server.py`).
- **CDP port 9222** is internal-only (no ingress, no Cloudflare DNS).
- **WebRTC media needs no ingress rule.** It relays through coturn over the
  allocation neko opens outbound, which is stateful return traffic.

## Display — neko WebRTC (since 2026-08-11)

The live view at `chrome.viktorbarzin.me` is [neko](https://neko.m1k1o.net) v3:
hardware-free software **x264 H.264 at 1920x1080@30** plus **Opus audio**, with a
window manager and live resolution changes from the UI. It replaced the previous
noVNC (`x11vnc` + `websockify`) view — design and rationale in
`docs/plans/2026-08-11-chrome-service-neko-display-design.md`.

**neko owns the browser.** The pod runs the stock upstream
`ghcr.io/m1k1o/neko/google-chrome` image (digest-pinned in `local.neko_image`),
which brings its own Xorg, openbox, PulseAudio and capture pipeline and launches
real Google Chrome as its single app. The `google-chrome` variant — not
`chromium` — because the proprietary H.264/AAC codecs are the reason this stack
moved off bundled Chromium in the first place (see "Browser binary" above).

**Chrome's flags are ours, not upstream's.** neko launches the browser from a
plain supervisord program file, so a ConfigMap mounted (subPath) over
`/etc/neko/supervisord/google-chrome.conf` keeps chrome-service's own launch
line inside an unmodified image — no fork, no custom build. Source of truth:
`files/neko/google-chrome.conf`, which documents every flag delta. Notably it
keeps `--user-data-dir=/profile/chromium-data`, so the warmed profile did not
move and needed no migration (both neko's `neko` user and the previous container
run as uid 1000, and the PVC is owned `1000:1000`).

**CDP is republished by a sidecar.** Chrome binds CDP to loopback on `:9223`
(stock builds ignore `--remote-debugging-address`), and the neko image ships no
python3, so `cdp_bridge.py` moved from inside the browser container to its own
`cdp-bridge` sidecar in the same netns. Callers keep hitting `:9222` unchanged.

**Media path.** WebRTC relays through coturn. A `turn-cred` initContainer mints
an ephemeral coturn TURN-REST credential at every pod start (`files/turn_cred.py`,
unit-tested in `files/turn_cred_test.py`) and writes the ICE-server JSON to a
shared `emptyDir`; the neko container exports those files before exec'ing
supervisord, because neko reads ICE servers from env and env can't be computed at
pod start. Nothing long-lived needs rotating by hand.

**Two gates.** Authentik forward-auth on the ingress (`Chrome Users`, ADR-0023)
plus neko's own admin password from Vault
(`secret/chrome-service.neko_admin_password`). A bookmark with `?pwd=<value>`
keeps it one click. The user-role password is a fresh random value generated per
pod start, which makes the view-only role unusable by design — the admin
password is the only way in. Two gates rather than one because this browser holds
every cookie logged in by hand.

**Fallback.** `capture.screencast` is enabled (JPEG over HTTP, 10 fps, quality
60) for a client that cannot establish WebRTC at all. Upstream is explicit that
it is high-latency and not a primary stream; it fills the role noVNC used to.

**Probes.** One liveness probe on the neko container covers two failure modes:
`/health` (neko server) and CDP `/json/version` (the wedged-Chrome class a TCP
probe misses, since a wedged Chrome keeps its port open). Restarting that
container takes supervisord down with it, so Chrome comes back. The bridge
sidecar's readiness gates the `chrome-service` Service so no CDP caller is routed
before Chrome is reachable.

### Retired with noVNC

The two x11vnc gotchas that used to live here are gone along with the sidecar,
its `chrome-service-novnc` image and the `build-chrome-service-novnc.yml`
workflow. Kept as a short record in case an old pod spec resurfaces:

- **fd-sweep (stuck "Connecting")** — containerd grants pods
  `RLIMIT_NOFILE = 2^31` and x11vnc `fcntl`-swept the entire fd table on every
  client connect, so the RFB handshake never completed. Fixed by capping
  `ulimit -n 65536` before x11vnc started.
- **Black view after a browser restart** — x11vnc attached to the browser
  container's Xvfb over `localhost:6099`; when that container restarted, x11vnc
  exited and was never relaunched. Fixed by supervising x11vnc and websockify so
  either one dying restarted the sidecar.

Neither applies to neko, which owns its own X server inside the same container as
the capture pipeline.

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
drive the browser — over the neko view OR the CDP/`homelab browser` path — can
reach the persistent profile (`browser.contexts[0]`) and therefore Viktor's
sessions. Access is gated accordingly, per user.

**Decision (2026-06-28):** emo (`emil.barzin` / `emil.barzin@gmail.com`) SHARES
Viktor's browser for form-filling + captcha solving, rather than getting an
isolated instance. The session-exposure trade-off above was explicitly accepted.

Two independent grants make up "browser access" for a user:

1. **neko (interactive view, `chrome.viktorbarzin.me`)** — gated by the Authentik
   `admin-services-restriction` policy via the **`Chrome Users` group** (ADR-0023;
   the `chrome`/`chrome-fleet` ingresses set `allowed_groups = ["Chrome Users"]`).
   Add the user to `Chrome Users` — kept deliberately tighter than admin, though
   `Home Server Admins` also pass via the break-glass bypass. No kubeconfig/RBAC
   needed. (Was a hardcoded `CHROME_ALLOWED` username/email set until 2026-07-26.)
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

**To grant another user:** add them to the `Chrome Users` group (the view) and/or add a
`<user>-browser` SA + bindings mirroring `emo-browser` in `rbac.tf` (CLI), then run
the provisioner. To revoke: remove from `Chrome Users` and delete the SA (rotate
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
hand login in the view, the persistent profile PVC, the hourly `storage_state()` snapshot,
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
