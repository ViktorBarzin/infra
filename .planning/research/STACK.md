# Stack Research

**Domain:** Live stream aggregation and proxy service (F1 streams)
**Researched:** 2026-02-23
**Confidence:** HIGH (versions verified against PyPI, GitHub releases, and official docs)

---

## Recommended Stack

### Core Technologies

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| Python | 3.13 (image: `python:3.13-slim-bookworm`) | Backend runtime | Latest stable; JIT in 3.13 helps CPU-bound m3u8 rewriting; `python:3.13-slim-bookworm` is the official minimal production image. Async-native for concurrent stream proxying. |
| FastAPI | 0.132.0 | HTTP API + stream relay | Async-first ASGI framework with native streaming response support (`StreamingResponse`). Best-in-class for HTTP proxy patterns where you relay chunked data. Built-in OpenAPI docs. Pydantic integration. |
| yt-dlp | 2026.2.21 | Stream URL extraction | De-facto standard for extracting final HLS URLs from obfuscated sites. Supports 1000+ extractors, handles redirect chains, CSRF cookies, JS-rendered pages. Used as a Python library (`yt_dlp.YoutubeDL`), not just CLI. Updated continuously — this is critical for staying current with sites that change obfuscation. |
| Playwright (Python) | 1.58.0 | JS-rendered scraping | Required for sites that serve stream links only after JavaScript execution. `playwright.async_api` integrates naturally with FastAPI's async event loop. Use only when yt-dlp extractors don't cover the target site — Playwright is the fallback for custom per-site extractors. Chromium headless. |
| Svelte 5 + SvelteKit 2 | Svelte 5.53.3 / SvelteKit 2.53.0 | Frontend | Matches user's stated preference. Svelte 5's runes reactivity model is stable and production-ready. SvelteKit 2 provides SSR + SPA routing. Minimal bundle size matters for embedded player page. |
| hls.js | 1.6.15 | In-browser HLS playback | Native `<video>` does not support HLS on non-Safari. hls.js is the only production-grade MSE-based HLS player. Handles adaptive bitrate switching. Integrates trivially into Svelte via `onMount`. |
| FastF1 | 3.8.1 | F1 race schedule data | Wraps jolpica-f1 API (Ergast-compatible) with built-in caching, pandas DataFrames, and Python-native models. Direct replacement for the deprecated Ergast API. Provides race schedule, session times, round numbers. |
| Redis | 7.x (existing cluster: `redis.redis.svc.cluster.local`) | Extracted URL caching, dedup | Extracted HLS URLs are expensive (JS render + redirect chain). Cache them with TTL (15–30 min). Existing Redis in cluster — zero additional infra. Use `redis-py` (async: `redis.asyncio`). |
| APScheduler | 3.11.2 | Schedule polling cron | Runs the F1 schedule sync job (daily) and triggers scrape jobs before sessions. AsyncIOScheduler integrates with FastAPI lifespan. Avoids needing a separate Celery worker for simple periodic tasks at this scale. |

### Supporting Libraries

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| httpx | 0.28.1 | Async HTTP client for scraping | Use for fetching pages and following redirect chains without JS. Preferred over `requests` in async context (requests is sync-only). Supports HTTP/2, connection pooling, cookie jars. |
| BeautifulSoup4 | 4.14.3 | HTML parsing for link extraction | Parse scraped HTML to find stream link candidates before handing to yt-dlp. Use with `lxml` parser (faster). Only needed for custom extractors; yt-dlp handles most internally. |
| m3u8 | 6.0.0 | HLS playlist parsing and rewriting | Parse master playlists to rewrite segment URLs through the proxy. Required if you relay streams (rewrite absolute URLs → proxy URLs). |
| Pydantic | 2.12.5 | Data models and validation | FastAPI already depends on it. Use for `StreamSource`, `RaceEvent`, `ExtractorResult` models. Pydantic v2 is significantly faster than v1 (Rust-backed). |
| aiosqlite | 0.22.1 | Lightweight persistent store | Store race schedule cache and scrape job state. Single pod → no concurrency issues with SQLite. Use for data that outlives Redis TTL (schedule, extractor configs). |
| streamlink | 8.2.0 | Secondary stream extractor | Plugin-based extractor as an alternative/complement to yt-dlp. Has different coverage. Use as fallback when yt-dlp lacks an extractor for a specific site. Can also pipe stream bytes directly. |
| python-multipart | latest | Form data parsing | Required by FastAPI for any form-based endpoints. |
| uvicorn | latest | ASGI server | FastAPI production server. Use `uvicorn[standard]` (includes uvloop + httptools for 2x throughput). |
| redis-py | 5.x | Redis async client | `redis.asyncio.from_url(...)` — async Redis client. Part of the `redis` package. |
| Tailwind CSS | 4.2.1 | Frontend styling | v4 is stable. Zero-runtime CSS. Works natively with SvelteKit via Vite plugin. |

### Development Tools

| Tool | Purpose | Notes |
|------|---------|-------|
| Vite 8 | Frontend build | SvelteKit 2.53.0 ships with Vite 8. No separate install needed. |
| pytest + pytest-asyncio | Backend tests | Test extractors and stream proxy logic. `pytest-asyncio` for async route tests. |
| ruff | Python linting + formatting | Replaces flake8 + black + isort. Single fast binary. |
| mypy | Type checking | FastAPI + Pydantic 2 provide good type inference. Catches extractor return type bugs early. |
| Playwright test runner | Extractor integration tests | Use `playwright codegen` to record site interactions for new extractors. |

---

## Installation

```bash
# Backend (Python 3.13)
pip install fastapi==0.132.0 uvicorn[standard] httpx==0.28.1
pip install yt-dlp==2026.2.21 playwright==1.58.0 streamlink==8.2.0
pip install fastf1==3.8.1 apscheduler==3.11.2
pip install beautifulsoup4==4.14.3 lxml m3u8==6.0.0
pip install pydantic==2.12.5 aiosqlite==0.22.1 redis==5.x
pip install python-multipart

# Install Playwright browser binaries (in Dockerfile)
playwright install chromium --with-deps

# Frontend (Node/SvelteKit)
npm create svelte@latest frontend
npm install -D tailwindcss @tailwindcss/vite
npm install hls.js
```

---

## Alternatives Considered

| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| FastAPI + Python | Go + gin/fiber | If throughput > 10k concurrent streams. Go is more efficient at raw TCP proxying, but Python's yt-dlp/playwright ecosystem has no equivalent in Go — would require subprocess shelling out. Python wins for this use case. |
| yt-dlp (library) | yt-dlp (subprocess) | Never subprocess — library mode gives direct access to extractor info_dict, format selection, and cookie jars without shell overhead. |
| APScheduler | Celery | Celery requires a separate worker process + broker queue. APScheduler runs in-process. Overkill for 2 periodic jobs (schedule sync + pre-session scrape trigger). Use Celery only if scrape jobs need distributed execution across many workers. |
| hls.js | Video.js + @videojs/http-streaming | Video.js (v8.23.4) wraps hls.js internally but adds significant bundle overhead. Use hls.js directly in Svelte for minimal footprint and full control. |
| Redis (existing) | In-memory dict cache | In-memory cache is lost on pod restart (K8s). Redis provides persistence across restarts + shared state if you ever run multiple replicas. Already in cluster at no cost. |
| SvelteKit | Next.js / Nuxt | User preference is Svelte. SvelteKit's adapter-node works well in Docker/K8s. Bundle size advantage matters for embedded player page load time. |
| FastF1 | Direct Jolpica API calls | FastF1 adds built-in caching, retry logic, and Python models. Saves implementing Ergast-compatible parsing from scratch. jolpica-f1 API endpoint: `https://api.jolpi.ca/ergast/f1/<season>/races/` |
| Playwright (Python) | Selenium | Playwright is faster, has async API, and Chromium headless is more stable than Selenium's ChromeDriver setup. Playwright's `page.route()` lets you intercept XHR/fetch calls to capture stream URLs without loading full pages. |
| aiosqlite | PostgreSQL | PostgreSQL is overkill for single-node persistent schedule cache. SQLite with aiosqlite on NFS is fine for read-heavy, write-rare schedule data. If you need multi-pod writes, migrate to PostgreSQL. |

---

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| `requests` library | Synchronous only — blocks the event loop in async FastAPI handlers, causing stream proxy delays | `httpx` (drop-in async replacement with identical API style) |
| `youtube-dl` | Archived/unmaintained since 2021. yt-dlp is the maintained fork with 3x more extractors and weekly updates. Sites actively break youtube-dl. | `yt-dlp` |
| Selenium | Heavy (~500MB browser + driver), poor async support, ChromeDriver version pinning causes constant breakage in K8s | `playwright` (native async, auto-manages browser binaries) |
| Django | Sync-first ORM, not designed for long-lived streaming HTTP connections. FastAPI handles `StreamingResponse` for chunked relay natively. | `FastAPI` |
| FFmpeg-based re-encoding | Introduces CPU-intensive transcode step, adds latency, and is unnecessary — HLS segments are already in a playable format. Proxy segments as-is. | Direct HLS segment relay (fetch + stream through) |
| Tornado | Was the async Python standard before asyncio. Replaced by asyncio-native frameworks. Less ecosystem support. | `FastAPI` + `uvicorn` |
| Celery for simple scheduling | Requires Redis as broker + a separate worker pod. Two extra moving parts for tasks that can run in-process. | `APScheduler` (AsyncIOScheduler in FastAPI lifespan) |
| `m3u8` for full stream relay | Segment-by-segment proxying via Python is high-latency (Python overhead per segment fetch). Use HTTP redirect for public segments; only rewrite the playlist if segments require auth cookies. | Redirect to original segments where possible; only proxy if cookies are required |

---

## Stack Patterns by Variant

**If a site requires only cookie passing (no JS rendering):**
- Use `httpx` with cookie jar from initial login request
- Extract HLS URL from HTML with BeautifulSoup4 or regex
- No Playwright needed; much faster startup

**If a site requires JavaScript execution to reveal the stream URL:**
- Use Playwright async API: `page.route()` to intercept XHR requests containing `.m3u8` URLs
- Use `page.evaluate()` to extract obfuscated CSRF tokens from JS context
- Cache the result in Redis with 20-minute TTL

**If the HLS segments require authentication cookies:**
- Use m3u8 library to rewrite segment URLs → point to proxy endpoint
- Proxy endpoint fetches segments with stored cookies and streams back bytes
- Required when segments have signed URLs or cookie gates

**If yt-dlp has an extractor for the site:**
- Use `yt_dlp.YoutubeDL(opts).extract_info(url)` — returns `formats` list with direct HLS URLs
- Much simpler than custom Playwright extractor; always try yt-dlp first

---

## Version Compatibility

| Package | Compatible With | Notes |
|---------|-----------------|-------|
| FastAPI 0.132.0 | Pydantic 2.x | FastAPI 0.100+ requires Pydantic v2. Do not mix with Pydantic v1. |
| SvelteKit 2.53.0 | Vite 8.x | SvelteKit 2.53.0 explicitly added Vite 8 support (Feb 2025). |
| yt-dlp 2026.2.21 | Python 3.9+ | yt-dlp follows CalVer; latest version works with Python 3.13. |
| Playwright 1.58.0 | Python 3.9+ | Requires `playwright install chromium` in Dockerfile. Chromium 145.0.7632.6. |
| APScheduler 3.11.2 | Python 3.8+ | Use `AsyncIOScheduler` with `asyncio` event loop. APScheduler 4.x is in beta — stick with 3.x. |
| FastF1 3.8.1 | Python 3.10+ | Requires Python 3.10+. Uses jolpica-f1 API under the hood (Ergast-compatible). |
| hls.js 1.6.15 | Modern browsers | MSE required (Chrome, Firefox, Edge). No iOS Safari (use native HLS). |
| redis-py 5.x | Redis 7.x | `redis.asyncio` for async usage. Cluster in infra already runs Redis 7.x. |
| Tailwind CSS 4.2.1 | Vite 8 | Tailwind v4 uses Vite plugin (`@tailwindcss/vite`), not PostCSS config. Breaking change from v3. |

---

## Sources

- PyPI: yt-dlp 2026.2.21 — https://pypi.org/project/yt-dlp/ (HIGH confidence, verified Feb 2026)
- PyPI: FastAPI 0.132.0 — https://pypi.org/project/fastapi/ (HIGH confidence, verified Feb 2026)
- PyPI: Playwright 1.58.0 — https://pypi.org/project/playwright/ (HIGH confidence, verified Feb 2026)
- PyPI: httpx 0.28.1 — https://pypi.org/project/httpx/ (HIGH confidence, verified Feb 2026)
- PyPI: APScheduler 3.11.2 — https://pypi.org/project/APScheduler/ (HIGH confidence, verified Feb 2026)
- PyPI: FastF1 3.8.1 — https://pypi.org/project/fastf1/ (HIGH confidence, verified Feb 2026)
- PyPI: Pydantic 2.12.5 — https://pypi.org/project/pydantic/ (HIGH confidence, verified Feb 2026)
- PyPI: BeautifulSoup4 4.14.3 — https://pypi.org/project/beautifulsoup4/ (HIGH confidence, verified Feb 2026)
- PyPI: aiohttp 3.13.3 — https://pypi.org/project/aiohttp/ (HIGH confidence, verified Feb 2026)
- PyPI: aiosqlite 0.22.1 — https://pypi.org/project/aiosqlite/ (HIGH confidence, verified Feb 2026)
- PyPI: streamlink 8.2.0 — https://pypi.org/project/streamlink/ (HIGH confidence, verified Feb 2026)
- PyPI: m3u8 6.0.0 — https://pypi.org/project/m3u8/ (HIGH confidence, verified Feb 2026)
- PyPI: requests 2.32.5 — https://pypi.org/project/requests/ (HIGH confidence, verified Aug 2025)
- GitHub: svelte 5.53.3 — https://github.com/sveltejs/svelte/releases (HIGH confidence, verified Feb 2026)
- GitHub: SvelteKit 2.53.0 — https://github.com/sveltejs/kit/releases (HIGH confidence, verified Feb 2026)
- GitHub: hls.js 1.6.15 — https://github.com/video-dev/hls.js/releases (HIGH confidence, verified)
- GitHub: Tailwind CSS 4.2.1 — https://github.com/tailwindlabs/tailwindcss/releases (HIGH confidence, verified Feb 2026)
- GitHub: Traefik v3.6.9 — https://github.com/traefik/traefik/releases (HIGH confidence, verified Feb 2026)
- GitHub: jolpica-f1 — https://github.com/jolpica/jolpica-f1 (MEDIUM confidence — Ergast API replacement, community-maintained)
- GitHub: Python Docker images — https://github.com/docker-library/python/blob/master/versions.json (HIGH confidence — python:3.13-slim-bookworm, Python 3.13.12)
- GitHub: Video.js v8.23.4 — https://github.com/videojs/video.js/releases (HIGH confidence, confirmed hls.js is preferred for direct integration)
- PyPI: Celery 5.6.2 — https://pypi.org/project/celery/ (HIGH confidence — confirmed as overkill vs APScheduler for this use case)

---

*Stack research for: F1 stream aggregation and proxy service*
*Researched: 2026-02-23*
