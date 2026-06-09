# Roadmap: F1 Streaming Service

## Overview

Build a private F1 stream aggregation service from the ground up: first the Kubernetes
deployment stack, then the F1 schedule subsystem, then the per-site extraction pipeline,
then health checking and fallback ordering, then the HLS proxy and relay layer, then
CDN token lifecycle management, and finally the Svelte frontend. Each phase delivers
a verifiable, independently testable capability that the next phase depends on. The
system is complete when a user opens one URL during a live F1 session and immediately
sees working, proxied streams with a functioning embedded player.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [ ] **Phase 1: Infrastructure and Deployment** - Terragrunt stack on K8s with NFS storage — service exists on the cluster
- [ ] **Phase 2: F1 Schedule Subsystem** - Pull, persist, and serve the F1 race calendar from OpenF1/jolpica API
- [ ] **Phase 3: Extractor Framework and First Site** - Plugin registry, BaseExtractor interface, first working site extractor with background polling
- [ ] **Phase 4: Stream Health and Fallback** - Pre-display health verification, dead stream marking, quality metrics, and fallback ordering
- [ ] **Phase 5: HLS Proxy Core** - CORS-transparent m3u8 proxy with full URI rewriting and chunked segment relay
- [ ] **Phase 6: CDN Token Lifecycle and Quality** - Token refresh loops for long-running sessions and quality variant selection
- [ ] **Phase 7: Frontend Core — Schedule, Picker, and Player** - SvelteKit app with schedule view, stream picker, and embedded hls.js player
- [ ] **Phase 8: Multi-Stream Layout** - Side-by-side stream viewing for watching multiple feeds simultaneously

## Phase Details

### Phase 1: Infrastructure and Deployment
**Goal**: The F1 service exists on the Kubernetes cluster, is reachable at its domain, and has NFS storage mounted — ready to run application code.
**Depends on**: Nothing (first phase)
**Requirements**: DEPL-01, DEPL-02
**Success Criteria** (what must be TRUE):
  1. A request to the service's public URL returns a non-error HTTP response from the cluster
  2. The Terragrunt stack applies cleanly from a fresh checkout with no manual cluster intervention
  3. The NFS volume is mounted inside the running pod and a file written to it survives a pod restart
  4. Woodpecker CI pipeline exists and triggers on push to the service's directory
**Plans**: 2 plans
Plans:
- [ ] 01-01-PLAN.md — Create FastAPI backend app, Dockerfile, and build/push Docker image
- [ ] 01-02-PLAN.md — Update Terraform deployment, apply stack, verify NFS, add CI pipeline

### Phase 2: F1 Schedule Subsystem
**Goal**: The system automatically fetches the full F1 race calendar and serves it as structured data — users can see all sessions for the current season with correct times.
**Depends on**: Phase 1
**Requirements**: SCHED-01
**Success Criteria** (what must be TRUE):
  1. The `/schedule` API endpoint returns all races for the current season with session types (FP1-3, Qualifying, Sprint, Race) and UTC-correct timestamps
  2. Schedule data persists to NFS and is served correctly after a pod restart without re-fetching the API
  3. APScheduler triggers a background refresh of schedule data at least once daily without manual intervention
  4. A race that has already occurred shows a "past" status and an upcoming race shows "upcoming" status
**Plans**: TBD

### Phase 3: Extractor Framework and First Site
**Goal**: The extractor plugin system is in place and at least one site extractor returns a valid, live HLS URL — proving the end-to-end extraction architecture.
**Depends on**: Phase 2
**Requirements**: EXTR-01, EXTR-02, EXTR-03
**Success Criteria** (what must be TRUE):
  1. The extractor registry lists all registered site extractors and dispatches to the correct one by site key
  2. The first site extractor returns a working m3u8 URL that plays when pasted into VLC, including passing any CSRF or token requirements
  3. Background polling runs automatically on the APScheduler, re-extracts streams at a configured interval, and caches results in Redis with a TTL
  4. Adding a second extractor requires only creating a new class file and registering it — no changes to the dispatcher or other extractors
  5. Extractor failures are logged with enough detail to identify exactly which step failed (request, token parse, URL extraction)
**Plans**: TBD

### Phase 4: Stream Health and Fallback
**Goal**: Only verified-live streams reach users, broken streams are flagged, and when multiple sources exist the system automatically tries the next one on failure.
**Depends on**: Phase 3
**Requirements**: HLTH-01, HLTH-02, HLTH-03, EXTR-05
**Success Criteria** (what must be TRUE):
  1. The `/streams` API endpoint only returns streams that have passed a HEAD/partial-GET liveness check within the last health-check interval
  2. A stream that returns a non-200 or empty playlist is marked as dead and excluded from the API response without manual intervention
  3. The `/streams` response includes bitrate and liveness metadata per stream so the frontend can display stream quality
  4. When configured with multiple sources for the same session, the API returns them in reliability-ranked order (most recently verified first)
**Plans**: TBD

### Phase 5: HLS Proxy Core
**Goal**: The proxy layer converts raw CDN HLS URLs into browser-playable same-origin URLs with full CORS support — a stream URL from the extractor can be played in any browser via the proxy.
**Depends on**: Phase 4
**Requirements**: PRXY-01, PRXY-02, PRXY-03
**Success Criteria** (what must be TRUE):
  1. Fetching `/proxy?url=<master-m3u8>` returns an m3u8 where every URI at every level (master, variant, segment) points back through the `/relay` endpoint — zero requests escape to the original CDN domain
  2. A browser playing a proxied stream completes all preflight CORS checks without errors, including the `Range` header
  3. Segment relay streams bytes to the browser as chunked transfer with no full-segment buffering — peak memory per active stream stays under 5 MB
  4. The proxy correctly handles both master playlists (multi-variant) and media playlists (single-variant) without special-casing at the caller
**Plans**: TBD

### Phase 6: CDN Token Lifecycle and Quality
**Goal**: Streams stay alive for full 2+ hour F1 sessions without user intervention, and users can select video quality when multiple variants are available.
**Depends on**: Phase 5
**Requirements**: EXTR-04, PRXY-04, PRXY-05
**Success Criteria** (what must be TRUE):
  1. A stream that has been playing for 90 minutes continues without interruption — the background token refresh loop re-extracts and updates the cached URL before the CDN token expires
  2. The `/streams` response exposes available quality variants (resolution labels) for streams that provide multi-variant playlists
  3. Selecting a different quality variant via the API returns a proxied URL for that specific variant stream
  4. Token refresh failures are logged and surface in stream health status without crashing the relay or affecting other active streams
**Plans**: TBD

### Phase 7: Frontend Core — Schedule, Picker, and Player
**Goal**: Users can open the service in a browser, see the F1 session schedule, pick a live stream from the available sources, and watch it in an embedded player on the same page.
**Depends on**: Phase 6
**Requirements**: FRNT-01, FRNT-02
**Success Criteria** (what must be TRUE):
  1. The schedule page lists all upcoming and past sessions grouped by Grand Prix, with correct local-timezone display and live/upcoming/past badges
  2. Clicking a live session shows a stream picker with available sources labeled by site name and liveness status
  3. Selecting a stream loads and begins playing it in the embedded hls.js player without leaving the page
  4. The player recovers from transient network errors automatically and displays a clear error message only on unrecoverable failure
  5. The app is usable on a desktop browser without requiring any browser extension or plugin
**Plans**: TBD

### Phase 8: Multi-Stream Layout
**Goal**: Users can watch multiple streams side by side simultaneously — for example, the main race feed alongside a specific driver onboard camera.
**Depends on**: Phase 7
**Requirements**: FRNT-03
**Success Criteria** (what must be TRUE):
  1. The user can add a second stream to the view and both play simultaneously in a split-screen layout without audio or video interference between streams
  2. The layout adapts gracefully when two streams are loaded — each player gets equal visible area and independent controls
  3. Removing one stream from the multi-stream view does not interrupt the other stream
**Plans**: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Infrastructure and Deployment | 0/2 | Planning complete | - |
| 2. F1 Schedule Subsystem | 0/TBD | Not started | - |
| 3. Extractor Framework and First Site | 0/TBD | Not started | - |
| 4. Stream Health and Fallback | 0/TBD | Not started | - |
| 5. HLS Proxy Core | 0/TBD | Not started | - |
| 6. CDN Token Lifecycle and Quality | 0/TBD | Not started | - |
| 7. Frontend Core — Schedule, Picker, and Player | 0/TBD | Not started | - |
| 8. Multi-Stream Layout | 0/TBD | Not started | - |
