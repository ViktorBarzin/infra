# Pitfalls Research

**Domain:** Live stream aggregation and proxy service (F1-focused)
**Researched:** 2026-02-23
**Confidence:** MEDIUM — findings synthesized from yt-dlp/streamlink source analysis (HIGH), nginx proxy documentation (HIGH), HLS RFC/spec analysis (HIGH), OpenF1 API docs (HIGH), and web searches that returned sparse results (LOW where noted)

---

## Critical Pitfalls

### Pitfall 1: Treating JavaScript-Rendered Tokens as Static

**What goes wrong:**
Stream URLs on sports streaming sites are not present in raw HTML. They are computed client-side by obfuscated JavaScript — the page HTML contains an encrypted or encoded config blob, and the actual HLS URL is assembled by executing that JS. A scraper that fetches the raw HTML page and runs a regex over it finds nothing.

**Why it happens:**
Developers assume "the URL must be somewhere in the page source." They inspect the page in DevTools, see the URL in the network tab, and try to replicate what they observe — but miss that the URL was produced by JS execution, not served in the initial response.

**How to avoid:**
- For each target site: trace the actual network request that fetches the m3u8 in browser DevTools (Network tab, filter by `.m3u8`). Identify the API endpoint that the JS calls to get the signed URL. Replicate *that* API call (often a JSON endpoint), not the page fetch.
- If the token is computed entirely client-side (e.g., via CryptoJS with a hardcoded key), implement the same algorithm in your extractor. Do not run headless browser — reverse-engineer the JS algorithm.
- Document which sites require JS execution vs. which expose a clean API endpoint. Sites often have a backend API that the JavaScript calls; scraping that API is faster and more stable than re-implementing the JS.

**Warning signs:**
- Extractor returns empty results on a page you can watch in the browser
- Network tab shows the m3u8 URL appearing only after JavaScript fires an XHR/fetch call
- Page HTML contains a large base64 blob or heavily obfuscated JS variable (e.g., `var _0x1a2b = [...]`)

**Phase to address:**
Extractor design phase (before writing a single extractor). Establish upfront: for each target site, determine if raw HTTP fetch is sufficient or if API reverse-engineering is required.

---

### Pitfall 2: m3u8 Segment URLs Break When Proxied Through a Different Domain

**What goes wrong:**
When you fetch an m3u8 playlist and serve it through your proxy, the segment URLs inside the playlist may be absolute URLs pointing to the original CDN. The browser (or HLS.js) follows those segment URLs directly, bypassing your proxy entirely. This means you cannot control access, cannot inject headers, and CORS blocks the segments if the CDN doesn't allow cross-origin requests from your frontend domain.

**Why it happens:**
HLS playlists can contain either absolute URLs (`https://cdn.example.com/seg001.ts`) or relative paths (`seg001.ts`). Most streaming CDNs use absolute URLs with signed tokens. Proxying only the m3u8 is insufficient — every segment URL must also be rewritten to route through your relay.

**How to avoid:**
- When serving the m3u8 through your proxy, **rewrite all segment URLs** to point to your relay endpoint before sending the playlist to the client. Example: replace `https://cdn.site.com/segment001.ts?token=xyz` with `https://your-relay.domain/proxy/segment?url=<encoded-original-url>`.
- Your relay endpoint then fetches the original segment and streams it to the client.
- Handle multi-level playlists: master playlists (variant streams) reference child playlists which reference segments — rewrite at each level.

**Warning signs:**
- Client-side CORS errors in browser console referencing the original CDN domain
- Network tab shows segment fetches bypassing your proxy after the m3u8 loads
- Some quality variants play but others don't (partial rewriting)

**Phase to address:**
Stream relay/proxy phase. Must be designed before the first end-to-end stream test.

---

### Pitfall 3: CDN-Signed Token URLs Expire Mid-Stream

**What goes wrong:**
Many CDNs sign stream URLs with a short-lived token (often 5–30 minutes). The m3u8 playlist URL itself may be signed, and so may each segment URL. A user who starts watching near the token expiry time will get a working stream for the first few segments, then receive 403 Forbidden errors as the token expires mid-playback.

**Why it happens:**
Developers test stream extraction, confirm the URL works, and ship it — without accounting for token TTL. The token was valid at extraction time but expires before or during playback. Live streams compound this: the m3u8 playlist updates every few seconds and each update may contain newly signed segment URLs. If your relay cached an old playlist, segments within it are expired.

**How to avoid:**
- Never cache m3u8 playlist files. Always fetch the live playlist from upstream on each client request. Cache only TS/m4s segments (which have longer or no expiry).
- When extracting the initial stream URL, record the extraction timestamp and the token TTL (if discoverable from response headers like `Cache-Control: max-age=N`). Re-extract before expiry.
- Implement a background refresh: when serving a stream, periodically re-run the extractor to get a fresh URL and pivot the relay to the new upstream without interrupting the client.
- Test expiry by extracting a URL and waiting 30 minutes before playing — a failing test here reveals token TTL issues.

**Warning signs:**
- Stream plays for exactly N minutes then fails with 403 on segments
- Extracting a URL works in isolation but fails when embedded in the player after a delay
- Sites with Cloudflare or custom CDN always add `?token=` or `?sig=` parameters to segment URLs

**Phase to address:**
Stream relay phase. The relay architecture must include a URL refresh loop from day one.

---

### Pitfall 4: Per-Site Extractor Maintenance Burden Is Dramatically Underestimated

**What goes wrong:**
Each target site is a custom engineering problem. Sites change their HTML structure, JavaScript obfuscation, API endpoints, or anti-bot measures without notice. A working extractor can break silently overnight. With 5 target sites, you effectively have 5 separate maintenance tracks. Expecting "set and forget" behavior is the most common planning mistake in this domain.

**Why it happens:**
Developers build an extractor, it works, and they move on. Sites then deploy a CDN update, change their frontend framework, or rotate their obfuscation keys. The failure is silent — no exception is raised, the extractor just returns no URL, and the user sees an empty player.

**How to avoid:**
- Build a health check system that runs each extractor on a schedule (every 15 minutes during race weekends, every hour otherwise), logs success/failure, and triggers alerts on failure.
- Design extractors with failure visibility: log exactly which step failed (page fetch, URL parse, API call, etc.) so debugging is fast.
- Keep extractor logic isolated and testable: each extractor is a module that takes no inputs and returns a stream URL or raises an exception. Run integration tests against live sites on a schedule.
- Plan 1–2 hours of maintenance per extractor per month as baseline, more during site redesigns.

**Warning signs:**
- No automated testing of extractors against live sites
- Extractor code tightly coupled to specific HTML element IDs or class names (breaks on any frontend change)
- No alerting when an extractor returns no URL

**Phase to address:**
Extractor design phase. The monitoring/health-check system must be built alongside the first extractor, not added later.

---

### Pitfall 5: Missing or Incorrect CORS Headers on the Relay Breaks Browser Playback

**What goes wrong:**
HLS.js in the browser makes cross-origin requests to fetch m3u8 playlists and segment files. If your relay doesn't serve the correct CORS headers, every segment request fails with a CORS error. Even a single missing header (e.g., on `.ts` segment responses but not `.m3u8` responses) breaks the stream.

**Why it happens:**
Developers test the relay with `curl` or server-to-server calls, where CORS is irrelevant. The relay works in isolation but fails when the browser's HLS.js player makes the requests.

**How to avoid:**
- Set CORS headers on **all** relay endpoints: `Access-Control-Allow-Origin: *` (or your specific frontend domain), `Access-Control-Allow-Methods: GET, HEAD, OPTIONS`, `Access-Control-Allow-Headers: Range`.
- The `Range` header is critical: HLS.js often sends range requests for segments. If `Range` is not in `Allow-Headers`, preflight OPTIONS requests fail.
- Do not use wildcard `*` if you also send `Access-Control-Allow-Credentials: true` — that combination is invalid and browsers reject it.
- Test from the actual browser environment (or use a CORS testing tool) before calling any relay endpoint "done."

**Warning signs:**
- Browser console shows `No 'Access-Control-Allow-Origin' header` errors
- Streams work when loaded directly in a `<video>` src but fail when loaded via HLS.js
- Preflight OPTIONS requests returning 405 Method Not Allowed

**Phase to address:**
Stream relay phase, first integration test.

---

### Pitfall 6: IP-Based Banning From Target Streaming Sites

**What goes wrong:**
Streaming sites detect and ban server IP ranges because your relay sends requests from a datacenter IP (K8s node) with no residential IP characteristics. The extractor initially works from a developer laptop (residential ISP), then fails when deployed to the cluster because the server IP is blocked or fingerprinted differently.

**Why it happens:**
Streaming sites use IP reputation databases. Cloud provider IP ranges (AWS, GCP, Hetzner, OVH, etc.) are pre-blocked or rate-limited on many streaming platforms. Your home cluster may or may not be in a residential IP range depending on your ISP.

**How to avoid:**
- Test extractors from the same environment they'll run in (the K8s cluster) before committing to a site as a target. A site that works from your laptop may be blocked from the server.
- Use realistic HTTP headers: `User-Agent` matching a current browser, `Accept`, `Accept-Language`, `Accept-Encoding` headers that match a real browser session. Missing or mismatched headers are a primary signal.
- Include `Referer` headers matching the expected source page. Many CDNs check that the referer is the streaming site itself before serving signed URLs.
- Rotate request patterns if hitting the same site repeatedly: add random delays, avoid predictable polling intervals.

**Warning signs:**
- Extractor works in local testing but returns 403/429 in deployment
- Sites return Cloudflare IUAM challenge pages (JS challenge) when scraped from the server IP
- Response body contains "Access Denied" or "Bot Detected" rather than the expected HTML

**Phase to address:**
Extractor design phase. Test against the production network before finalizing site targets.

---

## Technical Debt Patterns

Shortcuts that seem reasonable but create long-term problems.

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Hardcode stream URL for the first race | Ship fast | Breaks immediately; no automation | Never — defeats the purpose |
| Use `BeautifulSoup` regex on entire page HTML | Simple implementation | Breaks on any frontend change; misses JS-rendered content | Only for static HTML pages with predictable structure |
| Cache m3u8 playlists at the relay | Reduce upstream requests | Serves expired segment URLs; stream breaks mid-playback | Never for live content |
| Single-threaded sequential extractor polling | Simple code | Can't handle concurrent users fetching different streams | Only in MVP with a single stream |
| Skip extractor health checks for MVP | Faster to ship | Silent failures, no visibility into broken extractors | Only if you have < 1 stream and check manually |
| Proxy all segments (relay mode) without segment caching | Correct behavior | High bandwidth usage; each viewer multiplies bandwidth | Only at low viewer count (< 5) |
| Use headless browser for all extractors | Handles all JS | Slow (3–10s per extraction), high memory, complex ops | Fallback for sites that truly cannot be handled otherwise |

---

## Integration Gotchas

Common mistakes when connecting to external services.

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| Target streaming sites | Fetch the HTML page and regex for the stream URL | Identify the actual API endpoint the site JS calls; hit that directly |
| Target streaming sites | Ignore cookies and session state | Maintain a cookie jar per site; some sites require a session cookie from the homepage before serving stream API |
| Target streaming sites | Send requests without `Referer` header | Always set `Referer` to the page that would normally contain the player |
| CDN segment URLs | Use the same signed URL for the full stream duration | Re-fetch the m3u8 on each playlist poll to get freshly signed segment URLs |
| OpenF1 API (race schedule) | Call live-data endpoints during a session on the free tier | Free tier allows only historical data; live data costs €9.90/month — use F1 calendar static JSON for schedule |
| OpenF1 API | Assume the API is official F1 data | OpenF1 is a third-party fan project, not affiliated with F1; data may lag or be incorrect |
| Ergast API | Expect stable availability in 2026 | Ergast deprecated their API in late 2024; use OpenF1 or the unofficial `api.formula1.com` instead |
| HLS.js player | Load the proxied m3u8 URL directly without error handler | Always attach `hls.on(Hls.Events.ERROR, ...)` with media error recovery; live streams have transient failures |
| HLS.js player | Assume autoplay works | Browser autoplay policies block unmuted video. Always mute by default or show a play button |

---

## Performance Traps

Patterns that work at small scale but fail as usage grows.

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| Relay proxies all segment bytes | Works for 1 viewer; saturates uplink for 5+ | Serve the rewritten m3u8 but let clients fetch segments directly from CDN (only proxy the playlist) | > 3 concurrent viewers on a typical F1 stream (5–8 Mbps per viewer) |
| Polling all extractors every minute | Works with 1–2 sites; CPU/memory spike at race time | Poll only during race windows; use event-driven triggers from the schedule | Always — race starts matter, not constant polling |
| Synchronous extractor execution blocks the API response | First request takes 5–10s while extractor runs | Pre-warm extractors before the race start time; cache last-known working URL | First user to request a stream before pre-warming |
| No connection pooling to upstream CDNs | High segment fetch latency | Reuse HTTP connections with keep-alive | > 10 segments/second through the relay |
| Storing stream session state in memory (in-process) | Works on one pod | Lost on pod restart; user stream breaks | Any Kubernetes pod restart or rolling deployment |

---

## Security Mistakes

Domain-specific security issues beyond general web security.

| Mistake | Risk | Prevention |
|---------|------|------------|
| Exposing the raw upstream CDN URL in API response | Users bypass your relay; sites can track and block the raw URL if scraped | Keep upstream URLs server-side only; serve an opaque relay URL to the client |
| Open relay endpoint with no auth | Your relay becomes a public proxy for any content, burning bandwidth and attracting abuse | Require at minimum a shared secret or same-origin check; this is private infrastructure |
| Logging full signed CDN URLs | Signed URLs in logs = anyone with log access can watch the stream | Log only the site name and stream quality, not the signed URL |
| Storing site credentials (if target site requires login) in source code | Credentials rotate or get revoked; leaked credentials cause account bans | Use environment variables / Kubernetes secrets; never commit credentials |
| No rate limiting on the relay API | A single misbehaving client can exhaust bandwidth | Add rate limiting per IP on the `/proxy/` endpoints |

---

## UX Pitfalls

Common user experience mistakes in this domain.

| Pitfall | User Impact | Better Approach |
|---------|-------------|-----------------|
| Showing all streams including dead/offline ones | User clicks a stream, gets a black player; no indication of why | Pre-validate streams before the race and tag each as "live", "offline", or "extracting"; surface status in the stream picker |
| Player starts with audio on (bypassing autoplay mute) | Browser blocks autoplay; user sees a broken play state | Start muted by default; show a prominent unmute button |
| No stream quality selector | Users on slow connections buffer constantly | Expose the HLS quality levels via HLS.js API; let users pick |
| Race schedule shows times in UTC only | Users outside UTC miss sessions | Detect browser timezone and display in local time; let users configure their timezone |
| Stream picker has no quality or language indicator | User has to try each stream to find the best one | Label streams with: source site, resolution (1080p/720p/480p), language, and status |
| No loading state feedback during extraction | User sees blank screen for 5–10 seconds during extractor run | Show a "Finding stream..." spinner with a progress indicator |

---

## "Looks Done But Isn't" Checklist

Things that appear complete but are missing critical pieces.

- [ ] **Extractor for site X works:** Verify it works from the production K8s network (not just localhost) and handles the case where the site returns a challenge page
- [ ] **Stream proxy works:** Verify with HLS.js in a browser, not just with curl — CORS errors only appear in browser context
- [ ] **m3u8 rewriting works:** Verify that multi-level playlists (master → variant → segments) are all rewritten, not just the top-level m3u8
- [ ] **Token expiry handled:** Wait 30 minutes after extracting a URL, then try to play it — test that the refresh mechanism kicks in
- [ ] **Race schedule is accurate:** Verify timezone handling — F1 races in different countries, and session times shift with DST changes mid-season
- [ ] **Relay is actually private:** Confirm the relay endpoints are not publicly accessible without auth — check via Traefik ingress rules
- [ ] **Extractor monitoring alerts:** Trigger an extractor failure manually and verify an alert fires before the next race

---

## Recovery Strategies

When pitfalls occur despite prevention, how to recover.

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| Extractor breaks because site changed its JS | MEDIUM | Open browser DevTools on the site, re-trace the API call sequence, update the extractor; typical fix time 30–90 minutes per site |
| CDN-signed URL expires mid-stream | LOW | Restart the stream extraction (background refresh handles this if implemented); user may need to re-click play |
| Relay bandwidth saturated | MEDIUM | Switch relay strategy: serve rewritten m3u8 but redirect segment fetches directly to CDN (remove relay from segment path) |
| Site IP-bans the cluster | HIGH | Either accept the site as unavailable or route extractor requests through a residential proxy/VPN exit; may require re-evaluating the site as a target |
| OpenF1 API unavailable | LOW | Fall back to F1 calendar static JSON; race schedule data changes infrequently so a cached fallback is safe |
| HLS.js CORS errors in browser | LOW | Add missing `Access-Control-Allow-Origin` and `Access-Control-Allow-Headers: Range` to relay responses; deploy fix |

---

## Pitfall-to-Phase Mapping

How roadmap phases should address these pitfalls.

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| JS-rendered tokens not found in HTML | Extractor design (Phase 1) | Each extractor spec documents: "token source = API endpoint or JS algorithm" |
| m3u8 segment URLs bypass proxy | Stream relay (Phase 2) | End-to-end browser test: open Network tab and confirm zero requests go to original CDN domain |
| CDN token expiry mid-stream | Stream relay (Phase 2) | Play stream for 45 minutes; verify no 403 errors on segments |
| Extractor maintenance burden | Extractor design + monitoring (Phase 1 + Phase 3) | Health check system alerts fire within 5 minutes of extractor failure |
| Missing CORS on relay | Stream relay (Phase 2) | Browser-based smoke test with CORS error detection |
| IP-based banning | Extractor design (Phase 1) | Test all extractors from production network before finalizing site list |
| Silent extractor failures | Monitoring (Phase 3) | Inject a deliberate failure; verify alert reaches notification channel |
| Race schedule timezone errors | Schedule integration (Phase 1) | Test with browser timezone set to UTC+11 (Australia) and UTC-5 (Americas) |
| Open relay as public proxy | Infrastructure (Phase 2) | Verify relay endpoint returns 401/403 without auth from an external network |

---

## Sources

- yt-dlp `common.py` extractor base class source (HIGH confidence — production extractor framework): https://github.com/yt-dlp/yt-dlp/blob/master/yt_dlp/extractor/common.py
- yt-dlp contribution guidelines and extractor authoring notes (HIGH confidence): https://github.com/yt-dlp/yt-dlp/blob/master/CONTRIBUTING.md
- RFC 8216 — HTTP Live Streaming specification, segment URL and playlist requirements (HIGH confidence): https://datatracker.ietf.org/doc/html/rfc8216
- nginx `ngx_http_proxy_module` documentation — proxy buffering, URL rewriting, timeout configuration (HIGH confidence): https://nginx.org/en/docs/http/ngx_http_proxy_module.html
- OpenF1 API documentation — rate limits, live vs. historical data, usage rights (HIGH confidence): https://openf1.org/
- HLS.js API documentation — initialization order, error handling, quality level management (HIGH confidence): https://github.com/video-dev/hls.js/blob/master/docs/API.md
- MDN CORS documentation — credential restrictions, preflight requirements, header rules (HIGH confidence): https://developer.mozilla.org/en-US/docs/Web/HTTP/CORS
- F1 calendar site (f1calendar.com) — timezone complexity observations, session structure (MEDIUM confidence)
- Web search findings on streaming site anti-scraping techniques (LOW confidence — search returned sparse results for this specific domain)

---
*Pitfalls research for: F1 live stream aggregation and proxy service*
*Researched: 2026-02-23*
