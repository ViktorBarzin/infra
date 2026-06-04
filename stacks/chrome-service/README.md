# chrome-service

In-cluster headed Chromium exposed over the Chrome DevTools Protocol
(CDP) on TCP :9222. Sibling services drive it instead of running their
own in-process browser — useful when the upstream tries to detect
headless mode (e.g. hmembeds' `disable-devtool.js` redirect-to-google
trap). Also publishes an hourly snapshot of cookies + localStorage so
external dev-box Claude Code sessions can warm their isolated
playwright contexts from the same logged-in profile.

## Connect (in-cluster callers)

```python
from playwright.async_api import async_playwright

CDP_URL = "http://chrome-service.chrome-service.svc.cluster.local:9222"

async with async_playwright() as p:
    browser = await p.chromium.connect_over_cdp(CDP_URL, timeout=15_000)
    # browser.contexts[0] is the persistent default context (the one
    # the user logs into via noVNC). For bot work that should NOT share
    # cookies, create a fresh incognito context:
    context = await browser.new_context()
    await context.add_init_script(STEALTH_JS)
    page = await context.new_page()
    ...
    await browser.close()
```

NetworkPolicy is the only gate on the CDP endpoint — labelled client
namespaces or explicit fallback (`f1-stream`). No bearer token is
required for the connection itself.

## Snapshot endpoint (external callers)

```bash
# Bearer token comes from Vault secret/chrome-service.api_bearer_token.
TOKEN=$(vault kv get -field=api_bearer_token secret/chrome-service)
curl -fsSL \
  -H "Authorization: Bearer $TOKEN" \
  https://chrome.viktorbarzin.me/api/snapshot \
  > storage-state.json

# Use the snapshot with @playwright/mcp:
npx @playwright/mcp@latest --port 8931 --host localhost \
  --headless --browser chrome \
  --isolated --storage-state ./storage-state.json
```

The snapshot is refreshed hourly by the `chrome-service-snapshot-harvester`
CronJob (schedule `23 * * * *`) which calls `context.storageState()` via
the CDP endpoint and writes to `/profile/snapshots/storage-state.json`
(atomic rename). The `snapshot-server` sidecar serves that file.

## Add a new in-cluster caller

1. **Label the caller's namespace** so the chrome-service NetworkPolicy
   admits it:
   ```hcl
   resource "kubernetes_namespace" "<ns>" {
     metadata {
       labels = {
         "chrome-service.viktorbarzin.me/client" = "true"
       }
     }
   }
   ```
2. **Inject `CHROME_CDP_URL`** into the caller's pod env:
   ```hcl
   env {
     name  = "CHROME_CDP_URL"
     value = "http://chrome-service.chrome-service.svc.cluster.local:9222"
   }
   ```
3. **Vendor `stealth.js`** into the caller (or just paste — it's ~40
   lines) and apply via `await context.add_init_script(STEALTH_JS)` after
   every `new_context()`. Without it, hmembeds-class anti-bot still trips.

## Image pin

Both the server image (`mcr.microsoft.com/playwright:v1.48.0-noble` in
`main.tf`) and the client (`playwright==1.48.0` in callers' requirements)
must match minor-versions. Bump in lockstep — Playwright protocol changes
between minors.

## Operations

- **Storage**: encrypted PVC at `/profile`. Chromium user-data-dir lives
  at `/profile/chromium-data` — cookies + localStorage + IndexedDB
  persist here. Snapshots at `/profile/snapshots/storage-state.json`.
  Backed up tar+gzip every 6h to `/srv/nfs/chrome-service-backup/`,
  30-day retention.
- **Probes**: TCP/9222. Chrome's CDP serves `/json/version` once it's
  bound; TCP-open is enough for readiness.
- **Health page**: visit `https://chrome.viktorbarzin.me` (Authentik-
  gated) to confirm the pod is up and to log into sites. The CDP port
  stays internal-only.
- **Token rotation**: `vault kv put secret/chrome-service api_bearer_token=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')`.
  Reloader cascades to the snapshot-server sidecar. Update the cached
  token on any dev box that pulls the snapshot:
  `vault kv get -field=api_bearer_token secret/chrome-service > ~/.config/playwright/token`.

## Why headed (Xvfb) instead of headless?

`disable-devtool.js` and similar libraries detect `navigator.webdriver`,
console-clear timing, and the `HeadlessChromium/...` user-agent suffix.
Running headed inside `Xvfb :99` reports as a normal Chromium, and the
stealth init script handles the JS-visible giveaways.

## Why direct chromium (CDP) instead of `playwright launch-server`?

`playwright launch-server` creates ephemeral browser contexts per
`connect()` call — cookies and localStorage never persist to the PVC.
The `/profile` mount only ever held npm cache + fontconfig cache
despite the original docs claiming it held "cookies, localStorage,
IndexedDB". Switched 2026-06-04 to direct chromium launch with
`--user-data-dir=/profile/chromium-data --remote-debugging-port=9222`
so the persistent profile actually persists, and callers migrate
`chromium.connect(ws_url)` → `chromium.connect_over_cdp(cdp_url)`.
