# Feature Research

**Domain:** Live Stream Aggregation / Sports Stream Proxy Service
**Researched:** 2026-02-23
**Confidence:** MEDIUM

---

## Feature Landscape

### Table Stakes (Users Expect These)

Features users assume exist. Missing these = product feels incomplete.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| Race schedule view | Users need to know when sessions are live without external lookup | LOW | Pull from OpenF1 API (`/sessions` endpoint). Session types: FP1, FP2, FP3, Quali, Sprint, Sprint Quali, Race. Confidence: HIGH (OpenF1 API confirmed). |
| Live session indicator | Users need to distinguish live vs upcoming vs finished sessions at a glance | LOW | Visual status badge (LIVE / UPCOMING / FINISHED) based on session start time + duration. No polling needed at schedule level. |
| Stream picker | Multiple stream sources per session — user picks which one to watch | LOW | List available extracted stream links with source label. Core UX of the whole product. |
| Embedded video player | Users won't navigate to external players for each stream | MEDIUM | HLS.js in Svelte for in-page playback. Must handle m3u8 sources natively. Confidence: HIGH (HLS.js is the standard client-side HLS library). |
| Stream health indicator | Users don't want to click a dead stream and stare at a spinner | MEDIUM | Backend health-check each extracted URL before displaying. Simple HEAD or short-lived GET on the m3u8 playlist. Mark dead streams visually. |
| CORS-transparent stream proxy | Browsers block cross-origin HLS requests; streams can't play directly from scraped origins | HIGH | Proxy all m3u8 manifests + .ts/.m4s segments through your own backend. Rewrite manifest URLs to point to your proxy. This is architecturally mandatory, not optional. Confidence: HIGH (HLS-Proxy documentation confirms this). |
| All F1 session types covered | Users specifically want FP, Quali, Sprint, Race, and pre/post content — not just race day | MEDIUM | Scraper scheduler must run for every session type on the F1 calendar. OpenF1 `/sessions` endpoint returns `session_type` field. |
| Session countdown timer | For upcoming sessions, users want to know time-until-start without mental math | LOW | Client-side countdown from schedule data already fetched. Zero backend cost. |
| Stream auto-refresh / re-extraction | Stream links expire (tokens, redirect chains rotate) — stale links silently fail | HIGH | Periodic re-extraction (e.g., every 5-10 min during a live session). Depends on extractor infrastructure. |
| Multiple quality options (if available) | Users on slow connections need lower bitrate; users on fast connections want max quality | MEDIUM | Expose quality variants from multi-variant HLS playlists if source provides them. Let user pick or default to auto (hls.js handles ABR natively). |

---

### Differentiators (Competitive Advantage)

Features that set the product apart. Not required, but valuable.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| Automatic stream extraction at session start | Zero manual effort — streams appear when the session goes live | HIGH | Cron/scheduler tied to F1 calendar. Triggers extractors N minutes before session start. Eliminates "is there a stream yet?" manual checking. |
| Per-site extractor isolation | Bypassing CSRF/JS obfuscation cleanly per site without shared code that breaks globally | HIGH | Each extractor is a self-contained module. One site's changes don't break others. Confidence: MEDIUM (pattern from streamlink plugin system). |
| Session timeline: pre/post shows + press conferences | Competitors (scrapers, IPTV playlists) cover race only; full weekend coverage is rare | MEDIUM | Requires scheduling extractors for non-race events. OpenF1 does not cover pre/post shows — need site-specific session detection. |
| Stream source labeling | Shows which site/feed each stream came from — users learn which sources are reliable | LOW | Store source metadata with each extracted URL. Display in picker. |
| Fallback stream ordering | Automatically surfaces known-good streams first when multiple sources exist | MEDIUM | Health-check result + historical success rate drives ordering. Depends on: stream health checking + a minimal persistence layer to store success history. |
| Proxy-cached segment prefetch | Reduces buffering by prefetching upcoming .ts segments into local cache | HIGH | Node-HLS-Proxy pattern: maintain per-stream segment cache up to N segments ahead. High implementation cost for marginal UX gain at private scale. |
| Session notes / source reputation | Lightweight annotations (e.g., "this source often drops at lap 40") | LOW | Simple static config or admin-editable markdown. No database needed at MVP. |
| Race weekend overview page | One page showing all sessions for a Grand Prix weekend — not just next session | LOW | Group sessions by event/round from schedule API. Pure frontend feature once schedule data is available. |

---

### Anti-Features (Commonly Requested, Often Problematic)

Features to explicitly NOT build.

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| DVR / stream recording | Users want to rewatch if they miss something | Massive storage cost, legal exposure, complexity (recording live HLS streams, serving VOD). Out of scope by design. | Live viewing only. Accept the constraint. |
| Chat / comments | Social viewing experience | Scope creep. You're building a stream aggregator, not a community platform. Auth, moderation, and DB schema all follow. | None — explicitly out of scope. |
| User accounts / watchlists | "Remember my preferred stream source" | Requires auth layer, session storage, DB. Contradicts the "no auth, private URL" design decision. | Persist last-used quality/source in browser localStorage. Zero backend cost. |
| Stream transcoding / re-encoding | Normalize quality across sources | Enormous CPU cost, latency, and complexity. An FFmpeg transcoding pipeline per stream is overkill for a private service. | Pass-through proxy only. Let hls.js handle ABR on the client. |
| Headless browser extraction | Universal extractor that handles any site's JS obfuscation | Puppeteer/Playwright adds 200-400 MB RAM per session, slow cold starts, flaky in containers, and complex cluster scheduling. Per-site custom extractors are faster and more reliable. | Custom per-site extractors (Go/Python HTTP + regex/DOM parser). |
| Mobile app | Access on phone | Web app with responsive Svelte layout is sufficient. Native app is weeks of work for a private tool. | Responsive web design. PWA if needed. |
| Discovery / search for new stream sites | Auto-find new sources | Scraping discovery is an unsolved problem and a rabbit hole. You have a fixed list of sites. | User-provided site list. Extractor per site. |
| Telemetry overlay / timing data | F1 fans love live timing alongside streams | Different product category (timing dashboard vs stream aggregator). OpenF1 has timing data but integrating it is a separate project. | Link to existing timing tools (e.g., openf1.org). |
| DRM stream support | Some quality sources use Widevine/FairPlay | DRM circumvention is legally distinct from re-streaming. Avoid. | Non-DRM HLS sources only. |

---

## Feature Dependencies

```
Race Schedule View
    └──requires──> F1 Schedule API Integration (OpenF1 or Ergast)
                       └──enables──> Session Countdown Timer
                       └──enables──> Automatic Extraction Trigger

Stream Picker
    └──requires──> CORS-Transparent Stream Proxy (browser cannot directly fetch cross-origin m3u8)
    └──requires──> Stream Health Indicator (to filter dead streams before display)
                       └──requires──> Stream Health Checker (backend periodic HEAD/GET)

Embedded Video Player
    └──requires──> CORS-Transparent Stream Proxy (proxied URLs served from same origin)
    └──requires──> Stream Picker (to know which URL to play)

Stream Auto-Refresh
    └──requires──> Per-Site Extractor (to re-run extraction)
    └──requires──> Session-live detection (know when to run vs stop)

Fallback Stream Ordering
    └──requires──> Stream Health Indicator
    └──enhances──> Stream Picker (surfaces best streams first)

Multiple Quality Options
    └──requires──> CORS-Transparent Stream Proxy (proxy must rewrite variant playlist URLs too)
    └──enhances──> Embedded Video Player (user control or ABR)

Proxy-Cached Segment Prefetch
    └──requires──> CORS-Transparent Stream Proxy (must be same proxy layer)
    └──conflicts──> Minimal resource footprint (high memory cost)

Session Timeline (pre/post/press conf)
    └──requires──> F1 Schedule API Integration (for race events)
    └──requires──> Per-Site Session Detection (API doesn't include pre/post show timing)
```

### Dependency Notes

- **Stream Picker requires CORS proxy:** Browsers enforce same-origin policy. A scraped m3u8 URL from `site.com` cannot be fetched by a Svelte app on `f1.viktorbarzin.me`. Every user-facing stream URL must route through the proxy backend. This is a hard architectural dependency, not an option.
- **Stream health checker enables stream picker quality:** Without health checking, the picker shows dead links. Health checking must run before streams are displayed and periodically during live sessions.
- **Automatic extraction trigger depends on schedule:** The scheduler must know when sessions start. Schedule API integration is therefore the first thing to build — everything else gates on it.
- **Multiple quality options conflict with simple proxy:** If the source provides a multi-variant HLS playlist, the proxy must rewrite ALL variant URLs (not just the master manifest). Adds complexity to the proxy rewriting layer.
- **Fallback ordering conflicts with stateless proxy:** Tracking success history requires at least a lightweight persistence layer (e.g., Redis or SQLite). If staying fully stateless, fall back to health-check-only ordering.

---

## MVP Definition

### Launch With (v1)

Minimum viable product — what's needed to validate the concept.

- [ ] **F1 Schedule view** — Show upcoming/live sessions for the current season. Single page, no navigation needed.
- [ ] **CORS-transparent HLS proxy** — Proxy m3u8 manifests + segment URLs through the backend. Without this, nothing plays in the browser.
- [ ] **Per-site stream extractor(s)** — At least one working extractor for at least one reliable source site. Proves the extraction pipeline end-to-end.
- [ ] **Stream health checker** — Validate extracted URLs before showing. Dead streams must not surface to users.
- [ ] **Stream picker** — List available working streams for the current session. User clicks, player loads.
- [ ] **Embedded HLS player** — HLS.js in Svelte. Plays proxied m3u8 URL in-page.
- [ ] **Session countdown** — Time-until-start for upcoming sessions. Pure frontend, zero cost.
- [ ] **Live session indicator** — Visual LIVE/UPCOMING/FINISHED badge. Core navigational signal.

### Add After Validation (v1.x)

Features to add once core pipeline is working and streams actually play reliably.

- [ ] **Stream auto-refresh** — Re-run extractors every 5-10 min during live sessions. Trigger: user reports dead stream or health check fails on previously-valid URL.
- [ ] **Fallback stream ordering** — Sort by health-check recency and past reliability. Trigger: multiple sources available per session.
- [ ] **Source labeling in picker** — Show site name with each stream link. Low effort, high trust signal for users.
- [ ] **Race weekend overview** — All sessions grouped per Grand Prix. Trigger: users navigating between sessions in a weekend.
- [ ] **Additional extractors** — Expand site coverage once first extractor is stable. Each adds incremental reliability.

### Future Consideration (v2+)

Features to defer until product-market fit is established.

- [ ] **Pre/post show + press conference coverage** — Complex site-specific session detection. Defer until core race coverage is solid.
- [ ] **Multiple quality options** — Source sites may or may not provide multi-variant playlists. Complexity of rewriting variant URLs in proxy is non-trivial. Validate first if sources actually offer quality tiers.
- [ ] **Proxy segment prefetch/cache** — High memory cost. Only valuable if buffering is a real user complaint at private scale.
- [ ] **Session reputation annotations** — Nice UX polish. Not needed at launch.

---

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| F1 Schedule view | HIGH | LOW | P1 |
| CORS-transparent HLS proxy | HIGH | HIGH | P1 (architectural blocker) |
| Per-site stream extractor | HIGH | HIGH | P1 (core value) |
| Embedded HLS player | HIGH | LOW | P1 |
| Stream health checker | HIGH | MEDIUM | P1 |
| Stream picker | HIGH | LOW | P1 |
| Session countdown timer | MEDIUM | LOW | P1 |
| Live session indicator | HIGH | LOW | P1 |
| Stream auto-refresh | HIGH | MEDIUM | P2 |
| Source labeling | MEDIUM | LOW | P2 |
| Fallback stream ordering | MEDIUM | MEDIUM | P2 |
| Race weekend overview page | MEDIUM | LOW | P2 |
| Additional extractors | HIGH | MEDIUM | P2 |
| Multiple quality options | MEDIUM | HIGH | P3 |
| Pre/post show coverage | MEDIUM | HIGH | P3 |
| Proxy segment prefetch | LOW | HIGH | P3 |
| Session reputation annotations | LOW | LOW | P3 |

**Priority key:**
- P1: Must have for launch
- P2: Should have, add when possible
- P3: Nice to have, future consideration

---

## Competitor Feature Analysis

Reference products surveyed: RaceControl (unofficial F1TV client), f1viewer (TUI F1TV client), streamlink (stream extraction CLI), HLS-Proxy (node HLS proxy), Threadfin (M3U proxy), ErsatzTV (self-hosted IPTV).

| Feature | RaceControl (F1TV client) | Streamlink (CLI extractor) | HLS-Proxy (node) | Our Approach |
|---------|--------------------------|---------------------------|-----------------|--------------|
| Session schedule | F1TV API (official, auth required) | None (site-specific) | None | OpenF1/Ergast (free, unauthenticated) |
| Stream extraction | Official F1TV API | Plugin-per-site Python | N/A | Custom per-site extractors (Go/Python HTTP) |
| Stream quality selection | Multi-variant picker + Chromecast | CLI flag `--default-stream` | Pass-through | HLS.js ABR + manual picker |
| Multi-stream view | Yes (layout builder, experimental sync) | Multiple instances | N/A | Single stream (MVP), multi optional later |
| Health checking | None visible | None | None | Active periodic health checks (our differentiator) |
| Stream proxy | No (plays direct from F1TV CDN) | No (piped to local player) | Yes (manifest + segment rewrite) | Yes (mandatory for browser CORS) |
| CORS handling | N/A (desktop app) | N/A (local) | Yes (adds permissive CORS headers) | Yes (same-origin proxy) |
| Auto-extraction at session start | Via F1TV live schedule | None | None | Yes (scheduler + extractor trigger) |
| Embedded browser player | No (external VLC/mpv) | No (external player) | N/A | Yes (HLS.js in Svelte) |
| No auth required | No (F1TV subscription) | Varies by source | None | Yes (private URL, no auth layer) |

**Key insight:** Existing tools either require official F1TV credentials (RaceControl, f1viewer) or extract streams to local players (streamlink). None combine automated extraction from unofficial sources + browser-native proxied playback + schedule integration in a single web service. That combination is the product's core novelty.

---

## Sources

- OpenF1 API documentation: https://openf1.org/ — MEDIUM confidence (marketing page, limited technical detail on session endpoints)
- HLS-Proxy (warren-bank/HLS-Proxy) README — HIGH confidence for proxy architecture requirements (CORS, manifest rewriting, segment caching)
- HLS.js README (video-dev/hls.js) — HIGH confidence for client-side HLS capabilities (ABR modes, quality switching, error recovery)
- Streamlink documentation: https://streamlink.github.io/ — HIGH confidence for extraction patterns and plugin architecture
- yt-dlp README — HIGH confidence for extractor-per-site pattern and format selection
- RaceControl (robvdpol/RaceControl) README — MEDIUM confidence for F1 streaming UX expectations
- f1viewer (SoMuchForSubtlety/f1viewer) README — MEDIUM confidence for F1 session coverage expectations
- Threadfin README — MEDIUM confidence for IPTV/HLS proxy feature patterns
- Telly README — LOW confidence (Plex-specific, limited relevance)
- Eyevinn/hls-proxy README — HIGH confidence for HLS manifest manipulation patterns

---

*Feature research for: F1 Live Stream Aggregation Service*
*Researched: 2026-02-23*
