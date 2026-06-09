# Project Research Summary

**Project:** F1 Live Stream Aggregation and Proxy Service
**Domain:** Live stream aggregation, HLS proxy, sports scheduling
**Researched:** 2026-02-23
**Confidence:** MEDIUM (stack HIGH, architecture MEDIUM, features MEDIUM, pitfalls MEDIUM)

## Executive Summary

This project builds a self-hosted web service that aggregates live F1 streams from unofficial streaming sites, proxies them through the service to handle CORS and authentication, and presents them via an embedded HLS player with an F1 race schedule. The recommended approach is a Python/FastAPI backend (async, streaming-capable) paired with a Svelte 5/SvelteKit 2 frontend. The backend has four distinct responsibilities that must be built in dependency order: schedule data retrieval, per-site stream extraction, stream health checking, and HLS proxy/relay. Each component is independently testable and the architecture enforces clean separation so that one broken extractor cannot affect the rest of the system.

The core novelty of this product — and its hardest engineering challenge — is the per-site extractor subsystem. Each target streaming site uses custom anti-scraping measures (JS-rendered tokens, signed CDN URLs, IP-based blocking) that require a custom extractor per site, maintained independently. Existing tools (streamlink, yt-dlp) provide extraction patterns but not out-of-the-box support for private F1 streaming aggregators. The recommended approach treats yt-dlp as a first-pass extractor where it has coverage, and uses httpx + BeautifulSoup for custom extractors, with Playwright as a fallback only when JS execution is strictly required.

The primary risks are: (1) extractor brittleness — sites change without notice and extractors silently fail, requiring a health-check monitoring loop from day one; (2) CDN-signed URL expiry mid-stream, requiring the proxy to never cache m3u8 playlists and to implement background URL refresh; (3) IP-based blocking from the K8s cluster — all extractors must be tested from production network before finalizing site targets. These risks are all addressable through upfront architectural decisions rather than retrofitting.

---

## Key Findings

### Recommended Stack

The backend runs Python 3.13 on FastAPI 0.132.0 with uvicorn, using async throughout. yt-dlp 2026.2.21 is the primary extractor library (used as a Python library, not CLI). Playwright 1.58.0 (async Chromium) is the fallback for JS-rendered pages. httpx handles async HTTP for custom extractors. FastF1 3.8.1 provides the F1 race schedule via the Ergast-compatible jolpica API. APScheduler 3.11.2 runs periodic jobs (schedule refresh, extraction triggers) in-process without a separate worker. The existing cluster Redis is used for URL caching with TTL. SQLite via aiosqlite persists schedule snapshots to survive pod restarts.

The frontend is Svelte 5.53.3 / SvelteKit 2.53.0 (user preference, also well-suited for minimal bundle size). hls.js 1.6.15 handles in-browser HLS playback via MSE. Tailwind CSS 4.2.1 provides styling via the Vite plugin (not PostCSS — breaking change from v3). All infrastructure deploys as a single Terragrunt stack following the existing repo pattern.

**Core technologies:**
- **Python 3.13 + FastAPI 0.132.0**: Async-first, StreamingResponse for HLS relay, Pydantic models
- **yt-dlp 2026.2.21**: Primary stream extraction library — 1000+ extractors, Python library mode
- **Playwright 1.58.0**: JS-rendered page fallback — async API, `page.route()` for XHR interception
- **httpx 0.28.1**: Async HTTP for custom extractors and redirect chain following
- **FastF1 3.8.1**: F1 race schedule via jolpica API with built-in caching
- **APScheduler 3.11.2**: In-process async scheduler — avoids Celery overhead for 2 periodic jobs
- **hls.js 1.6.15**: Browser HLS playback via MSE — mandatory on non-Safari
- **Svelte 5 + SvelteKit 2**: Frontend framework (user preference, minimal bundle size)
- **Redis (existing cluster)**: Extracted URL cache with TTL — no additional infra cost
- **aiosqlite 0.22.1**: Schedule persistence to NFS — survives pod restarts

**Do not use:** `requests` (sync, blocks event loop), `youtube-dl` (unmaintained), Selenium (poor async/K8s support), FFmpeg re-encoding (unnecessary latency), Celery (overkill for 2 jobs).

### Expected Features

Research confirms this product's novelty: no existing tool combines automated extraction from unofficial sources + browser-native proxied playback + schedule integration in a single web service.

**Must have (table stakes):**
- F1 schedule view — show all session types (FP, Quali, Sprint, Race) with live/upcoming/finished indicator
- CORS-transparent HLS proxy — mandatory architectural requirement; streams cannot play in browser without it
- Per-site stream extractor — at least one working extractor proves the end-to-end pipeline
- Stream health checker — validates URLs before display; dead streams must not surface
- Stream picker — list available working streams, user clicks to load player
- Embedded HLS player — hls.js in Svelte, plays proxied m3u8 in-page
- Session countdown timer — client-side, zero backend cost
- Live session indicator — visual LIVE/UPCOMING/FINISHED badge

**Should have (add after MVP validation):**
- Stream auto-refresh — re-extract every 5-10 min during live sessions
- Fallback stream ordering — health-check + reliability history drives ordering
- Source labeling in picker — show site name with each stream
- Race weekend overview — all sessions grouped per Grand Prix
- Additional site extractors — expand coverage once first extractor is stable

**Defer (v2+):**
- Pre/post show and press conference coverage — complex site-specific session detection
- Multiple quality tiers — only if sources actually provide multi-variant playlists
- Proxy segment prefetch — high memory cost; only if buffering complaints emerge at scale
- Session reputation annotations — UX polish, not launch-critical

**Explicit anti-features (do not build):** DVR/recording, chat, user accounts, stream transcoding, DRM support, telemetry overlay.

### Architecture Approach

The system has five clearly bounded layers: (1) Schedule Subsystem — polls jolpica/OpenF1 API, stores to NFS; (2) Extractor Layer — plugin-per-site pattern with a registry dispatcher, concurrent fan-out execution; (3) Health Checker — validates extracted URLs via partial GET, stores liveness state in cache; (4) Proxy/Relay Layer — rewrites m3u8 URIs at all levels (master → variant → segments) through `/relay`; (5) Svelte Frontend — schedule view, stream picker, hls.js player. All state flows from extractors through cache to the API; the frontend never triggers extraction directly.

**Major components:**
1. **Extractor Registry** — maps site-key to extractor class; fan-out concurrent dispatch; one file per site
2. **Playlist Rewriter** — fetches upstream m3u8, rewrites all URIs to point through `/relay`; stateless
3. **Segment Relay** — pipes upstream `.ts`/`.m4s` bytes to client as chunked transfer; no buffering
4. **Schedule Subsystem** — daily cron via APScheduler, NFS persistence, jolpica API client
5. **Stream Health Checker** — background poller, HEAD/partial-GET on m3u8 URLs, results in Redis/memory cache
6. **Backend API (FastAPI)** — serves `/schedule`, `/streams`, `/proxy`, `/relay` endpoints; reads from cache only
7. **Svelte Frontend** — schedule page, watch page with stream picker and hls.js player

**Critical patterns:**
- Extraction runs on background schedule, never on client request (on-demand extraction = 10-30s wait)
- One extractor class per site; common `BaseExtractor` interface; isolation prevents cross-site failures
- Proxy must rewrite m3u8 at every level — master, variant, and segment; partial rewriting breaks streams
- Segment relay must stream bytes chunked, never buffer entire segment in memory

### Critical Pitfalls

1. **JS-rendered tokens not in HTML** — Before writing any extractor, trace network traffic in DevTools to find the actual API endpoint the site JS calls. Replicate the API call, not the page fetch. Using Playwright is the last resort; most sites expose a clean JSON API once reverse-engineered.

2. **m3u8 segment URLs bypass the proxy** — Rewrite all URLs in the playlist at every level (master → variant → segment). Verify with browser Network tab that zero requests reach the original CDN domain.

3. **CDN-signed URLs expire mid-stream** — Never cache m3u8 playlists in the relay. Always fetch the live playlist from upstream on each poll. Implement background URL refresh that re-extracts before token TTL expires.

4. **Extractor maintenance burden underestimated** — Sites break extractors without notice. Build health-check monitoring alongside the first extractor, not later. Alert on extractor failure within 5 minutes. Budget 1-2 hours/extractor/month for maintenance.

5. **IP-based blocking from K8s cluster** — Test all extractors from the production cluster network before finalizing site targets. Datacenter IPs are pre-blocked on many streaming platforms. Simulate realistic browser headers (User-Agent, Referer, Accept-Language).

6. **CORS missing on relay endpoints** — Set `Access-Control-Allow-Origin`, `Access-Control-Allow-Methods`, and `Access-Control-Allow-Headers: Range` on all relay responses. Missing `Range` header causes preflight failures for segment requests. Test from actual browser, not curl.

---

## Implications for Roadmap

The architecture's strict dependency chain dictates phase ordering. No phase can be skipped — each provides inputs required by the next. The recommended build order from ARCHITECTURE.md is confirmed by the pitfall analysis: the schedule subsystem must exist before extractors know when to run; extractors must work before the proxy has URLs to relay; the proxy must exist before the frontend has anything to play.

### Phase 1: Foundation — Schedule, Infrastructure, and Extractor Framework

**Rationale:** Schedule data is the trigger for everything downstream. Building the extractor framework (base class + registry) before writing any site-specific code prevents architectural lock-in. Both are low anti-scraping complexity — schedule uses a public API, framework is pure Python scaffolding.

**Delivers:** Working F1 schedule API endpoint, extractor plugin system with registry, Terragrunt deployment stack, NFS mount, development environment

**Addresses features:** F1 schedule view, live/upcoming/finished indicators, session countdown timer (frontend-only, depends on schedule data)

**Avoids pitfalls:** Establishes upfront which extraction approach each target site requires (API endpoint vs JS reverse-engineering vs Playwright); tests extractors from production network before committing to sites; implements timezone-aware schedule storage

**Research flag:** STANDARD — jolpica API is well-documented, Terragrunt stack pattern is established in repo

---

### Phase 2: Extraction Pipeline — First Working Extractor

**Rationale:** One end-to-end working extractor (raw URL → validated stream URL) proves the extraction architecture before scaling to multiple sites. Health checker must be built alongside first extractor — not after — because silent failures are the primary operational risk.

**Delivers:** First site extractor returning live HLS URLs, stream health checker (HEAD/GET validation), Redis caching with TTL, background polling scheduler

**Addresses features:** Per-site stream extractor, stream health checker, stream auto-refresh (background polling)

**Avoids pitfalls:** Extractor built with full failure visibility (logs which step fails); health-check alerts configured from day one; extractor tested from production K8s network before finalizing

**Research flag:** NEEDS RESEARCH DURING PLANNING — specific target sites unknown; each site requires independent reverse-engineering; Playwright requirement depends on site-specific JS analysis

---

### Phase 3: Stream Proxy and Relay Layer

**Rationale:** The proxy layer converts raw CDN URLs (which browsers cannot fetch cross-origin) into browser-playable same-origin URLs. This is the architectural blocker for the frontend — no proxy, no browser playback. Must be built before any UI work.

**Delivers:** `/proxy` endpoint (m3u8 fetch + full URI rewrite at all levels), `/relay` endpoint (chunked segment pipe-through), CORS headers on all relay responses, URL refresh loop for token expiry

**Addresses features:** CORS-transparent HLS proxy (mandatory for all browser playback), multiple quality options (variant playlist rewriting), stream picker (proxied URLs safe to expose to frontend)

**Avoids pitfalls:** Rewrites m3u8 at master + variant + segment levels; never caches playlists; streams segments as chunked transfer (no memory buffering); CORS headers include `Range` header; relay endpoint is not publicly accessible (Traefik auth)

**Research flag:** STANDARD — HLS spec (RFC 8216) and proxy patterns are well-documented; implementation is mechanical once architecture is understood

---

### Phase 4: Frontend — Schedule, Picker, and Player

**Rationale:** All backend components are independently testable via curl before the UI exists. The frontend is the final assembly step, not an intermediate one. Building it last means it integrates against a working backend rather than mocking everything.

**Delivers:** SvelteKit app with schedule view, stream picker, embedded hls.js player, session countdown timer, live/upcoming/finished badges

**Addresses features:** Embedded HLS player, stream picker, session countdown, live session indicator, race weekend overview (grouping sessions by Grand Prix)

**Avoids pitfalls:** hls.js error handler attached from day one; autoplay muted by default; streams display with source label and liveness status; timezone displayed in browser local time

**Research flag:** STANDARD — SvelteKit + hls.js integration is well-documented; component structure is straightforward given small scope

---

### Phase 5: Coverage Expansion and Reliability

**Rationale:** Once the full pipeline is proven end-to-end with one extractor, adding more sites is low-risk incremental work following the established pattern. Stream reliability features (fallback ordering, source labeling) are only meaningful once multiple sources exist.

**Delivers:** Additional site extractors (2-3 more sites), fallback stream ordering by health-check recency, source labels in stream picker, extractor monitoring alerts (notification channel)

**Addresses features:** Additional extractors, fallback stream ordering, source labeling, stream auto-refresh improvements

**Avoids pitfalls:** Each new extractor reverse-engineered independently; health-check alerts tested by deliberate failure injection before each race weekend

**Research flag:** NEEDS RESEARCH DURING PLANNING — each new target site requires individual analysis of extraction approach; cannot be planned generically

---

### Phase Ordering Rationale

- **Schedule first:** Public API, no anti-scraping complexity, required by extraction scheduler. Proves the Terragrunt stack without risking extractor failures.
- **Extractor framework before site-specific extractors:** Base class and registry must exist first; forces interface design before implementation.
- **Health checker with first extractor:** Silent failures are the top operational risk; monitoring must not be deferred.
- **Proxy before frontend:** The frontend's player cannot function without a working `/proxy` endpoint; building UI against a mock wastes time.
- **Frontend last of core phases:** All backend endpoints are curl-testable; UI is integration, not a prerequisite.
- **Additional extractors after core works:** Pattern is proven, risk is low, each site is independently scoped.

### Research Flags

Phases needing `/gsd:research-phase` during planning:
- **Phase 2 (Extraction Pipeline):** Target sites unknown; each requires independent DevTools session to determine extraction approach (API endpoint, JS algorithm, or Playwright). Cannot scope extractors without site-specific analysis.
- **Phase 5 (Coverage Expansion):** Each new target site is a fresh reverse-engineering problem. Budget per-site research before each extractor is scoped.

Phases with standard patterns (skip research-phase):
- **Phase 1 (Foundation):** jolpica/OpenF1 API is public and documented. Terragrunt stack follows established repo pattern. Extractor base class is standard Python ABC.
- **Phase 3 (Proxy/Relay):** HLS spec is RFC 8216. Proxy rewriting pattern is well-documented in HLS-Proxy and yt-dlp literature. CORS mechanics are standard.
- **Phase 4 (Frontend):** SvelteKit + hls.js integration has clear documentation. Component scope is small.

---

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | All versions verified against PyPI and GitHub releases as of 2026-02-23. Version compatibility matrix confirmed. |
| Features | MEDIUM | Feature list is well-grounded; competitor analysis confirms novelty. OpenF1 API confidence is MEDIUM (third-party fan project, not official F1). |
| Architecture | MEDIUM | HLS spec and proxy mechanics are HIGH confidence (RFC 8216, Apple docs). System composition for this specific use-case is inferred from domain patterns. |
| Pitfalls | MEDIUM | yt-dlp/streamlink source analysis and HLS RFC are HIGH; streaming site anti-scraping behavior is LOW (sparse public documentation). |

**Overall confidence:** MEDIUM

### Gaps to Address

- **Target site list not defined:** The research assumes a list of specific streaming sites to target but does not name them. Phase 2 cannot be scoped until specific sites are identified and reverse-engineered in a DevTools session. This is the largest planning gap.
- **OpenF1 live data cost:** OpenF1's live session data costs €9.90/month on free tier. Research recommends using the F1 calendar static JSON for schedule. Validate whether jolpica API provides sufficient real-time session status (live/upcoming) before finalizing the schedule integration approach.
- **Home ISP IP classification:** Whether the K8s cluster's home ISP IP is treated as residential or datacenter by streaming site IP reputation databases is unknown. Must test each target site from the cluster before committing. Recovery if blocked: residential proxy or VPN exit node.
- **Multi-variant playlist availability:** The multiple-quality feature depends on source sites providing multi-variant HLS playlists. This cannot be confirmed until specific sites are targeted. Phase 3 proxy rewriting should handle it correctly regardless, but the UX feature may not be usable at launch.
- **Token TTL per site:** Each site's CDN token TTL is unknown until extractors are built and tested. The background refresh architecture is in place, but the refresh interval must be configured per-site based on observed TTLs.

---

## Sources

### Primary (HIGH confidence)
- PyPI release pages — all stack versions (FastAPI, yt-dlp, Playwright, httpx, APScheduler, FastF1, Pydantic, hls.js, Tailwind CSS, SvelteKit, Svelte)
- RFC 8216 (IETF) — HLS specification, playlist structure, segment URL mechanics
- yt-dlp `common.py` + CONTRIBUTING.md — extractor plugin pattern, format selection
- HLS.js API documentation — initialization, error handling, quality level management
- MDN CORS documentation — preflight requirements, credential restrictions, header rules
- OpenF1 API documentation — rate limits, live vs. historical tiers, session endpoints

### Secondary (MEDIUM confidence)
- jolpica-f1 GitHub README — Ergast-compatible API, availability guarantees (community-maintained)
- Streamlink plugin documentation — per-site extractor isolation pattern
- HLS-Proxy (warren-bank) README — CORS proxy architecture requirements
- RaceControl (robvdpol), f1viewer (SoMuchForSubtlety) READMEs — F1 streaming UX expectations

### Tertiary (LOW confidence)
- Web searches on streaming site anti-scraping techniques — sparse results; pitfalls inferred from yt-dlp source patterns
- f1calendar.com — timezone complexity observations; not an authoritative source

---

*Research completed: 2026-02-23*
*Ready for roadmap: yes*
