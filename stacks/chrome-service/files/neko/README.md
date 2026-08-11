# `files/neko/` — what these two files override, and why

Both are mounted (subPath) over files that the stock
`ghcr.io/m1k1o/neko/google-chrome` image ships, so this stack keeps its own
browser behaviour inside an unmodified upstream image.

## `google-chrome.conf`

neko launches the browser from this supervisord program file. Ours keeps
chrome-service's launch line — the persistent profile at
`/profile/chromium-data`, CDP on `:9223`, and the anti-bot flags — and must also
carry `[program:openbox]`, because upstream ships both programs in this one file
and a subPath mount replaces the whole file. Per-flag rationale is in the file.

## `policies.json`

Upstream ships a Chrome **managed policy** tuned for a public kiosk browser.
Three of its entries are incompatible with what this stack is for, so this copy
is upstream's file with exactly three values changed (everything else, including
the force-installed uBlock Origin Lite + SponsorBlock extensions, is untouched):

| Key | Upstream | Ours | Why |
|---|---|---|---|
| `DeveloperToolsAvailability` | `2` (DevTools disallowed) | `0` (Chrome's default: allowed, except for force-installed extensions) | **This is the one that matters.** With `2`, browser-level CDP still answers `/json/version` and `Browser.getVersion`, but every per-page DevTools session is refused with `-32001 Session with given id not found`, so `connect_over_cdp` hangs and then times out. That breaks all five CDP callers. Verified by comparing against the pool worker's Chrome, where the identical raw auto-attach probe returns `{"result":{}}`. |
| `IncognitoModeAvailability` | `1` (incognito disabled) | `0` (available) | Playwright's `browser.new_context()` is implemented as `Target.createBrowserContext` — the incognito mechanism — so the fresh-context callers (tripit fares, `homelab browser`) need it. |
| `DownloadRestrictions` | `3` (block all downloads) | `0` (no special restriction) | The browser this replaced allowed downloads, and Playwright calls `Browser.setDownloadBehavior` on connect. |

If a future neko bump changes the upstream policy, re-diff it against this file
rather than assuming these are still the only three deltas.
