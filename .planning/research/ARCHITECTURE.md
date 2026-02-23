# Architecture Research

**Domain:** Live stream aggregation and proxy service (F1 streaming)
**Researched:** 2026-02-23
**Confidence:** MEDIUM — HLS spec and proxy mechanics are HIGH confidence from RFC 8216 and Apple docs; extractor patterns are MEDIUM confidence from yt-dlp/streamlink analysis; system composition for this specific use-case is inferred from domain knowledge.

---

## Standard Architecture

### System Overview

```
┌───────────────────────────────────────────────────────────────────┐
│                        CLIENT LAYER                               │
│  ┌──────────────────────────────────────────────────────────┐     │
│  │   Svelte Frontend (schedule view, stream picker, player)  │     │
│  └────────────────────────────┬─────────────────────────────┘     │
└───────────────────────────────│───────────────────────────────────┘
                                │ HTTP/REST
┌───────────────────────────────▼───────────────────────────────────┐
│                        API LAYER                                   │
│  ┌──────────────────────────────────────────────────────────┐     │
│  │   Backend API (schedule, streams, health state)           │     │
│  └────────┬──────────────────┬──────────────────────────────┘     │
└───────────│──────────────────│────────────────────────────────────┘
            │                  │
            ▼                  ▼
┌───────────────────┐  ┌──────────────────────────────────────────┐
│   SCHEDULE        │  │         EXTRACTION LAYER                  │
│   SUBSYSTEM       │  │  ┌───────────┐  ┌───────────┐            │
│                   │  │  │ Extractor │  │ Extractor │  ...        │
│ Jolpica/OpenF1    │  │  │ Site A    │  │ Site B    │            │
│ API client        │  │  └─────┬─────┘  └─────┬─────┘            │
│                   │  │        │               │                   │
│ Cron: refresh     │  │  ┌─────▼───────────────▼──────────────┐   │
│ schedule          │  │  │   Extractor Registry / Dispatcher   │   │
└───────────────────┘  │  └─────────────────────┬──────────────┘   │
                        │                        │                   │
                        │  ┌─────────────────────▼──────────────┐   │
                        │  │   Stream Health Checker             │   │
                        │  │   (HEAD/partial GET on .m3u8 URLs)  │   │
                        │  └─────────────────────────────────────┘   │
                        └──────────────────────────────────────────┘
                                          │
                                          ▼ valid stream URLs
                        ┌──────────────────────────────────────────┐
                        │         PROXY LAYER                       │
                        │                                           │
                        │  Master Playlist Rewriter                 │
                        │  ┌────────────────────────────────────┐   │
                        │  │ GET /proxy?url=<encoded-m3u8>       │   │
                        │  │  → fetch upstream m3u8              │   │
                        │  │  → rewrite all URIs to proxy paths  │   │
                        │  │  → return modified playlist         │   │
                        │  └────────────────────────────────────┘   │
                        │                                           │
                        │  Segment Relay                            │
                        │  ┌────────────────────────────────────┐   │
                        │  │ GET /relay?url=<encoded-segment>    │   │
                        │  │  → upstream fetch with headers      │   │
                        │  │  → pipe response to client          │   │
                        │  └────────────────────────────────────┘   │
                        └──────────────────────────────────────────┘
                                          │
                                          ▼ piped bytes
                        ┌──────────────────────────────────────────┐
                        │         STORAGE / CACHE                   │
                        │  ┌─────────────────┐  ┌───────────────┐  │
                        │  │ In-memory cache  │  │   NFS mount   │  │
                        │  │ (stream links,   │  │ (schedule     │  │
                        │  │  health status)  │  │  snapshots,   │  │
                        │  └─────────────────┘  │  config)      │  │
                        │                        └───────────────┘  │
                        └──────────────────────────────────────────┘
```

---

### Component Responsibilities

| Component | Responsibility | Typical Implementation |
|-----------|----------------|------------------------|
| **Svelte Frontend** | Schedule display, stream picker UI, embedded HLS player | SvelteKit app; hls.js or Video.js for player |
| **Backend API** | Serves schedule, current stream list, health status to frontend | Python (FastAPI) or Node.js; REST endpoints |
| **Schedule Subsystem** | Polls Jolpica/OpenF1 API, normalises session data, stores locally | Async background task with cron interval |
| **Extractor Registry** | Maps site hostnames to extractor implementations; dispatches extraction | Plain dict/map of site-key → extractor class |
| **Per-Site Extractor** | Performs HTTP requests with session cookies/CSRF, parses HTML/JS, follows redirect chains, returns raw stream URL | Python class per site; uses `httpx`/`requests` + `BeautifulSoup`/`regex` |
| **Stream Health Checker** | Verifies extracted URLs are live (partial GET on m3u8, checks HTTP 200 + content-type) | Background poller; marks streams up/down in cache |
| **Proxy / Playlist Rewriter** | Fetches upstream m3u8, rewrites all embedded URIs to go through `/relay`, returns modified playlist | Stateless HTTP handler; no buffering of media data |
| **Segment Relay** | Fetches upstream `.ts`/`.fmp4` segments and pipes bytes to client; forwards necessary headers | Streaming HTTP proxy (not buffered); forwards Range, Content-Type |
| **In-Memory Cache** | Stores current stream states and health, avoids redundant extraction on every client request | Python dict with TTL, or Redis (existing cluster Redis) |
| **NFS Storage** | Persists schedule snapshots, extractor configuration, optional diagnostics | NFS at `10.0.10.15` via existing pattern |

---

## Recommended Project Structure

```
f1-streams/
├── backend/
│   ├── api/
│   │   ├── routes/
│   │   │   ├── schedule.py     # GET /schedule
│   │   │   ├── streams.py      # GET /streams, POST /streams/refresh
│   │   │   └── proxy.py        # GET /proxy, GET /relay
│   │   └── main.py             # FastAPI app, lifespan hooks
│   ├── extractors/
│   │   ├── base.py             # Extractor ABC: extract() -> list[StreamInfo]
│   │   ├── registry.py         # Map site-key -> extractor class
│   │   ├── site_a.py           # Site-A specific extractor
│   │   └── site_b.py           # Site-B specific extractor
│   ├── schedule/
│   │   ├── client.py           # Jolpica/OpenF1 API client
│   │   ├── models.py           # Session, Race pydantic models
│   │   └── poller.py           # Background cron task
│   ├── health/
│   │   └── checker.py          # Stream liveness verification
│   ├── proxy/
│   │   ├── playlist.py         # m3u8 fetch + URI rewriting
│   │   └── relay.py            # Segment pipe-through handler
│   ├── cache.py                # In-memory store with TTL
│   └── config.py               # Site list, polling intervals, NFS paths
├── frontend/
│   ├── src/
│   │   ├── routes/
│   │   │   ├── +page.svelte    # Schedule home
│   │   │   └── watch/
│   │   │       └── +page.svelte # Stream picker + player
│   │   ├── lib/
│   │   │   ├── api.ts           # Backend API client
│   │   │   ├── player.ts        # hls.js wrapper
│   │   │   └── schedule.ts      # Session time formatting
│   │   └── app.html
│   ├── static/
│   └── package.json
├── stacks/
│   └── f1-streams/
│       ├── main.tf
│       └── terragrunt.hcl
└── Dockerfile                   # Multi-stage: backend + frontend
```

### Structure Rationale

- **backend/extractors/**: One file per site; base class enforces interface. Adding a new site = add one file + register it. No change to core.
- **backend/proxy/**: Isolated from extraction. Proxy only knows about URLs — it does not care how they were found.
- **backend/schedule/**: Completely independent subsystem. Can fail without breaking stream delivery.
- **backend/health/**: Decoupled checker; stores results in cache, consulted by API on `/streams` requests.
- **frontend/**: Standard SvelteKit layout. Minimal — schedule + player, nothing else.
- **stacks/f1-streams/**: Single Terragrunt stack following existing pattern in repo.

---

## Architectural Patterns

### Pattern 1: Extractor Plugin Interface

**What:** Each site extractor implements a fixed interface (`extract(session_hint) -> list[StreamURL]`). The registry maps site keys to extractor classes. The dispatcher iterates the registry, calls each extractor, aggregates results.

**When to use:** Always — the number of sites will grow and their anti-scraping measures change independently. Isolation prevents one broken extractor from affecting others.

**Trade-offs:** Slightly more boilerplate per site; but each extractor is testable in isolation and replaceable without touching shared code.

**Example:**
```python
class BaseExtractor(ABC):
    site_key: str  # e.g. "siteA"

    @abstractmethod
    async def extract(self, hint: SessionHint | None = None) -> list[StreamURL]:
        """Return list of live stream URLs found on this site."""
        ...

class SiteAExtractor(BaseExtractor):
    site_key = "siteA"

    async def extract(self, hint=None) -> list[StreamURL]:
        # 1. GET page, parse CSRF token from HTML
        # 2. POST with token to get obfuscated JSON
        # 3. Decode JS-obfuscated URL
        # 4. Follow redirects to final .m3u8
        ...
```

### Pattern 2: Playlist Rewriting Proxy

**What:** The proxy layer fetches the upstream m3u8 and rewrites every URL inside it (both master → variant pointers, and variant → segment pointers) to point back through `/relay?url=<base64-encoded-original>`. The client never contacts upstream directly.

**When to use:** Always when proxying HLS — the player will follow URLs in the playlist; if those URLs point to the origin CDN, the proxy is bypassed for segment delivery.

**Trade-offs:** Adds ~1 hop latency per segment request. For a private service with 1-5 users, this is negligible. Benefit: hides origin, enables header injection (e.g., `Referer`), unified player experience.

**Example:**
```python
def rewrite_playlist(m3u8_text: str, base_url: str, proxy_base: str) -> str:
    """Rewrite all URIs in an m3u8 to go through the proxy relay endpoint."""
    lines = []
    for line in m3u8_text.splitlines():
        if line and not line.startswith("#"):
            # resolve relative URL, then encode through proxy
            absolute = urllib.parse.urljoin(base_url, line)
            proxied = f"{proxy_base}/relay?url={b64encode(absolute)}"
            lines.append(proxied)
        else:
            lines.append(line)
    return "\n".join(lines)
```

### Pattern 3: Background Polling with In-Memory Cache

**What:** Extraction and health checking run as background tasks on a schedule (e.g., every 2 minutes). Results are stored in a shared in-memory dict with timestamps. The API layer reads from cache and returns immediately — no per-request extraction.

**When to use:** Always — on-demand extraction per client request would be slow (2-10s per site) and would hammer the source sites.

**Trade-offs:** Cache staleness window (default 2 min). Acceptable for live sports: streams stay stable once live.

**Example:**
```python
# cache.py
_stream_cache: dict[str, CachedResult] = {}

async def get_streams() -> list[StreamURL]:
    if cache_is_fresh():
        return _stream_cache["streams"].data
    # else trigger background refresh
    ...
```

---

## Data Flow

### Stream Discovery Flow (background)

```
[Cron trigger: every 2 min]
        ↓
[Extractor Registry]
        ↓ (fan-out, concurrent)
[SiteA Extractor]   [SiteB Extractor]   [SiteN Extractor]
        ↓
[Raw stream URLs: list of .m3u8 candidates]
        ↓
[Health Checker: partial GET each URL]
        ↓ (filter: only HTTP 200 + video/mpegURL content-type)
[Validated stream URLs]
        ↓
[Cache: store with timestamp + site metadata]
```

### Client Playback Flow (per request)

```
[User opens /watch in browser]
        ↓
[Frontend GET /api/streams]
        ↓
[Backend reads cache → returns stream list (site, quality, label)]
        ↓
[User picks a stream]
        ↓
[Player requests: GET /proxy?url=<m3u8-url>]
        ↓
[Backend: fetch upstream m3u8, rewrite URIs → return modified m3u8]
        ↓
[Player follows variant playlist: GET /proxy?url=<variant-m3u8>]
        ↓
[Backend: rewrite segment URIs]
        ↓
[Player fetches segments: GET /relay?url=<segment>]
        ↓
[Backend: upstream fetch, pipe bytes → client]
        ↓
[Video plays in browser]
```

### Schedule Flow

```
[Cron: daily or on-demand]
        ↓
[Schedule Client: GET Jolpica API /ergast/f1/current.json]
        ↓
[Parse: races, session types, UTC timestamps]
        ↓
[Normalise: map to internal Session model]
        ↓
[Store: NFS JSON file + in-memory cache]
        ↓
[Frontend GET /api/schedule → displays session list]
```

### Key Data Flows

1. **Extraction → Cache → API → Frontend**: All stream data originates from extractors, flows through the cache as the single source of truth, and is served read-only to the frontend. No frontend-triggered extraction.
2. **Client → Proxy → Upstream CDN**: The proxy is a pure pass-through relay. It does not store segments. Bytes from upstream go directly to client socket.
3. **Schedule API → NFS**: Schedule data is written to NFS on refresh so the pod can serve it immediately on restart without waiting for the next API poll.

---

## Component Boundaries

| Component | Owns | Does Not Own |
|-----------|------|--------------|
| Extractor (per site) | How to get stream URL from that site | Health checking, caching, proxying |
| Health Checker | Liveness state of each URL | How the URL was found |
| Proxy / Relay | Rewriting m3u8 URIs, piping bytes | Authentication with upstream (that's extractor's job) |
| Schedule Subsystem | F1 session calendar data | Stream availability for a given session |
| Backend API | Serving current state to frontend | Fetching or refreshing state |
| Frontend | User interaction, player | Any backend logic |

---

## Suggested Build Order (Phase Dependencies)

The dependencies flow strictly upward — each layer depends only on the layer below it being stable:

```
Phase 1: Schedule Subsystem
    ↓ (F1 data available)
Phase 2: Extractor Framework + First Site Extractor
    ↓ (raw URLs available)
Phase 3: Health Checker
    ↓ (validated URLs available)
Phase 4: Proxy / Relay Layer
    ↓ (streams playable through service)
Phase 5: Frontend (schedule + player)
    ↓ (end-to-end usable)
Phase 6: Additional Site Extractors
    ↓ (stream coverage widened)
Phase 7: K8s Deployment (Terraform/Terragrunt stack)
```

**Rationale:**
- Schedule first: gives a testable data source with zero anti-scraping complexity.
- Extractor framework before specific sites: the base class and registry must exist before any site can plug in.
- Health checker before proxy: no point proxying dead streams; the checker filters the list fed to the proxy.
- Proxy before frontend: the frontend player needs a working `/proxy` endpoint to function.
- Frontend last of core: all backend components are independently testable via curl/httpie before a UI exists.
- Additional extractors after core is working: adding more sites is low-risk incremental work once the pattern is proven.
- Deployment last: deploy once the service works end-to-end locally; avoids debugging infra and app simultaneously.

---

## Anti-Patterns

### Anti-Pattern 1: On-Demand Extraction Per Client Request

**What people do:** Trigger extraction when the user clicks "show streams" in the browser.

**Why it's wrong:** Extraction takes 2-10 seconds per site (HTTP round trips, JS parsing, redirect following). With multiple sites, this is 10-30 seconds of wall time. Source sites may rate-limit aggressive bursts. Multiple concurrent users would multiply the load.

**Do this instead:** Run extraction on a background schedule. Cache results. The API returns immediately from cache. The user sees streams in <100ms.

### Anti-Pattern 2: Single Extractor Handles All Sites

**What people do:** One big function with `if site == "A": ... elif site == "B": ...` branches.

**Why it's wrong:** Sites change their obfuscation methods independently. A change to Site A's extraction logic can accidentally break Site B. Testing is impossible in isolation. Adding Site C requires modifying a shared file.

**Do this instead:** One class per site, implementing a common interface. Changes to Site A's extractor never touch Site B's code.

### Anti-Pattern 3: Buffering Segments in Memory Before Sending

**What people do:** Download the entire `.ts` segment to memory, then serve it to the client.

**Why it's wrong:** HLS segments can be 2-10 MB each. With multiple concurrent viewers, memory pressure grows quickly. Introduces unnecessary latency (client waits for full download before first byte).

**Do this instead:** Pipe bytes from the upstream response directly to the client socket as they arrive (chunked transfer). The client starts receiving immediately, memory stays flat.

### Anti-Pattern 4: Hardcoding Site URLs and Tokens in Extractor Logic

**What people do:** Hardcode `BASE_URL = "https://site-a.example.com"` and referer/cookie values inside the extractor file.

**Why it's wrong:** Sites change domains and anti-scraping parameters frequently. When a site moves, you have to find and edit code rather than config.

**Do this instead:** Extractor reads its config (base URL, required headers, any known static tokens) from a config object injected at construction. The registry passes config to extractors at instantiation.

---

## Integration Points

### External Services

| Service | Integration Pattern | Notes |
|---------|---------------------|-------|
| Jolpica F1 API (`api.jolpi.ca/ergast/f1/`) | REST GET, poll daily | No API key required; backwards-compatible Ergast endpoints; schedule data available |
| OpenF1 API (`api.openf1.org/`) | REST GET, poll as needed | No API key; 3 req/s rate limit; 2023+ data only; useful for session status (live/upcoming) |
| Upstream streaming sites (Site A, B, N) | HTTP GET/POST with session cookies, CSRF tokens | Per-site; no shared pattern; treated as black boxes by the framework |
| Upstream CDN (HLS segments) | HTTP GET with Range support | Proxy relays bytes; must forward `Referer` and sometimes `Origin` headers or CDN rejects |

### Internal Boundaries

| Boundary | Communication | Notes |
|----------|---------------|-------|
| Extractor → Cache | Direct function call (write) | Extractors do not call the cache directly — the dispatcher aggregates results then writes once |
| API → Cache | Direct read | Synchronous, O(1) |
| API → Proxy | Not direct — frontend calls `/proxy` endpoint, which is part of the same backend process | Can be split into separate service later if needed |
| Proxy → Upstream CDN | Outbound HTTP | Must preserve session headers; upstream CDN may check Referer/Origin |
| Schedule Poller → NFS | File write (JSON) | On pod restart, reads NFS before first API poll |

---

## Scaling Considerations

This is a single-user or small-group private service. Scaling is not a primary concern, but here are the natural pressure points:

| Scale | Architecture Adjustments |
|-------|--------------------------|
| 1-5 concurrent viewers | Single backend pod, in-memory cache, direct pipe relay — fully sufficient |
| 10-20 concurrent viewers | Same architecture; segment relay becomes the bandwidth bottleneck (each viewer streams independently) — add HLS caching proxy (nginx) in front of relay |
| 50+ concurrent viewers | Segment relay load increases linearly; consider a CDN or caching layer for segments; extraction/health remain unchanged |

### Scaling Priorities

1. **First bottleneck:** Outbound bandwidth on segment relay. Each viewer pulls full bitrate independently through the service. At private-use scale this is negligible (1-5 viewers).
2. **Second bottleneck:** In-memory cache invalidation if multiple pods deploy (stateless pods don't share cache). Solved by using existing cluster Redis instead of in-process dict — but unnecessary until horizontal scaling.

---

## Sources

- HLS specification: RFC 8216 (IETF) — playlist structure, master/media playlist relationship, segment mechanics (HIGH confidence)
- HLS proxy pattern: Apple Developer Documentation (conceptual), corroborated by yt-dlp extractor framework analysis (MEDIUM confidence)
- yt-dlp plugin architecture: github.com/yt-dlp/yt-dlp README + docs (MEDIUM confidence)
- OpenF1 API: openf1.org official page — endpoints, rate limits, data coverage (HIGH confidence)
- Jolpica F1 API: github.com/jolpica/jolpica-f1 — Ergast compatibility, availability (MEDIUM confidence)
- System composition for this domain: inference from domain patterns, corroborated by extractor tool analysis (MEDIUM confidence)

---

*Architecture research for: Live stream aggregation and proxy service (F1)*
*Researched: 2026-02-23*
