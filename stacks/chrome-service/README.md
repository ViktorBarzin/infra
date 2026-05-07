# chrome-service

In-cluster headed Chromium exposed over Playwright's WebSocket protocol.
Sibling services drive it instead of running their own in-process browser
— useful when the upstream tries to detect headless mode (e.g. hmembeds'
`disable-devtool.js` redirect-to-google trap).

## Connect

```python
from playwright.async_api import async_playwright

WS_URL   = "ws://chrome-service.chrome-service.svc.cluster.local:3000"
WS_TOKEN = os.environ["CHROME_WS_TOKEN"]   # 32-byte URL-safe random

async with async_playwright() as p:
    browser = await p.chromium.connect(f"{WS_URL}/{WS_TOKEN}", timeout=15_000)
    context = await browser.new_context()
    await context.add_init_script(STEALTH_JS)   # see files/stealth.js
    page = await context.new_page()
    ...
    await browser.close()
```

The token comes from Vault KV `secret/chrome-service.api_bearer_token`,
which ESO syncs into a per-namespace K8s Secret in each caller stack
(see f1-stream's `chrome-service-client-secrets`).

## Add a new caller

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
2. **Add an ExternalSecret** in the caller stack pulling the token:
   ```hcl
   resource "kubernetes_manifest" "chrome_token" {
     manifest = {
       apiVersion = "external-secrets.io/v1beta1"
       kind       = "ExternalSecret"
       metadata = { name = "chrome-service-client-secrets", namespace = "<ns>" }
       spec = {
         refreshInterval = "15m"
         secretStoreRef  = { name = "vault-kv", kind = "ClusterSecretStore" }
         target          = { name = "chrome-service-client-secrets" }
         dataFrom        = [{ extract = { key = "chrome-service" } }]
       }
     }
   }
   ```
3. **Inject `CHROME_WS_URL` + `CHROME_WS_TOKEN`** into the caller's pod env.
   Use `secret_key_ref` for the token; the URL is a plain value.
4. **Vendor `stealth.js`** into the caller (or just paste — it's ~40 lines)
   and apply via `await context.add_init_script(STEALTH_JS)` after every
   `new_context()`. Without it, hmembeds-class anti-bot still trips.

## Image pin

Both the server image (`mcr.microsoft.com/playwright:v1.48.0-noble` in
`main.tf`) and the client (`playwright==1.48.0` in callers' requirements)
must match minor-versions. Bump in lockstep — Playwright protocol changes
between minors.

## Operations

- **Storage**: encrypted PVC at `/profile` for cookies + npm cache. Ephemeral
  contexts (`browser.new_context()`) bypass the profile; persistent contexts
  share it. Backed up tar+gzip every 6h to `/srv/nfs/chrome-service-backup/`,
  30-day retention.
- **Probes**: TCP/3000. Playwright run-server has no HTTP `/health`; a TCP
  open is the only liveness signal available without spinning a browser.
- **Health page**: visit `https://chrome.viktorbarzin.me` (Authentik-gated)
  to confirm the pod is up. The WS port stays internal-only.
- **Token rotation**: `vault kv put secret/chrome-service api_bearer_token=$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')`.
  Reloader cascades the rotation to both the server pod and any caller
  whose secret has the `reloader.stakater.com/auto = "true"` annotation.

## Why headed (Xvfb) instead of headless?

`disable-devtool.js` and similar libraries detect `navigator.webdriver`,
console-clear timing, and the `HeadlessChromium/...` user-agent suffix.
Running headed inside `Xvfb :99` reports as a normal Chromium, and the
stealth init script handles the JS-visible giveaways.
