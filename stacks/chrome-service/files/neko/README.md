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

## browser-bridge is force-installed here (2026-09-21)

`policies.json` carries a third forcelist entry,
`hleocpbgnegeofflmfijfanenkmcndai` against
`https://browser-bridge.viktorbarzin.me/crx/update.xml`, plus the matching
allowlist entry because the blocklist is `*`.

Two reasons, and the second is the one that earned it.

**It gives every agent a bridge target that is always up.** Until now
`homelab browser bridge` only reached a browser a human had personally
enrolled, so an agent with no human at a keyboard had nothing to drive.

**It closes the development loop.** An unpacked extension never
auto-updates, so testing a fix meant asking Viktor to download a zip,
remove the extension and load it again, for every single build. Four
attempts at one bug took an afternoon that way, and three of them shipped
against a browser still running the previous code. Chrome on Linux honours
a forcelist against a self-hosted update URL, so this instance picks up
each release on its own and can be driven end to end from here.

Note for anyone debugging a conflict: Chrome allows one debugger client per
tab. `homelab browser run` attaches Playwright over CDP, browser-bridge
attaches `chrome.debugger`. They coexist because each works in tabs it
created, but both pointed at the same tab will not.
