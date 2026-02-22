# Requirements: F1 Stream

**Defined:** 2026-02-17
**Core Value:** Users can find working F1 streams quickly — the app automatically discovers, validates, and surfaces healthy streams while removing dead ones.

## v1 Requirements

Requirements for initial release. Each maps to roadmap phases.

### Scraper Validation

- [ ] **SCRP-01**: Scraper filters Reddit posts by F1 keywords before extracting URLs (existing behavior, preserve)
- [ ] **SCRP-02**: Scraper validates each extracted URL by proxy-fetching it and checking for video/player content markers (video tags, HLS/DASH manifests, common player libraries)
- [ ] **SCRP-03**: URLs that don't look like streams (no video markers detected) are discarded before saving
- [ ] **SCRP-04**: Validation has a configurable timeout (default 10s) to avoid blocking on slow sites

### Health Checking

- [ ] **HLTH-01**: Background health checker service runs every 5 minutes against all known streams (scraped + user-submitted)
- [ ] **HLTH-02**: Health check performs HTTP reachability check first (does the URL respond with 2xx?)
- [ ] **HLTH-03**: If HTTP check passes, health checker proxy-fetches the page and checks for video/player content markers
- [ ] **HLTH-04**: Health check has a configurable timeout per check (default 10s)
- [ ] **HLTH-05**: Each stream tracks consecutive failure count, last check time, and healthy/unhealthy status in persisted state
- [ ] **HLTH-06**: Stream marked unhealthy after 5 consecutive health check failures
- [ ] **HLTH-07**: Unhealthy streams hidden from public streams page (`GET /api/streams/public`)
- [ ] **HLTH-08**: Unhealthy streams continue to be checked — restored to healthy if they recover (failure count resets)
- [ ] **HLTH-09**: Health check interval configurable via `HEALTH_CHECK_INTERVAL` env var (default 5m)

### Auto-publish Pipeline

- [ ] **AUTO-01**: Scraped streams that pass both scraper validation and initial health check are auto-published to the main streams page
- [ ] **AUTO-02**: Dead streams (unhealthy after 5 failures) are dynamically removed from the public page without admin intervention
- [ ] **AUTO-03**: Auto-published streams are distinguishable from user-submitted streams in the data model (source field)

### Secure Embedding

- [ ] **EMBED-01**: Proxy fetches stream page and attempts to extract direct video source URL (HLS .m3u8, DASH .mpd, direct MP4/WebM, or embedded video player source)
- [ ] **EMBED-02**: When direct video source is found, render it in a minimal HTML5 video player on the app's own page (no third-party page loaded)
- [ ] **EMBED-03**: When direct extraction fails, fall back to rendering the full proxied page in a shadow DOM sandbox
- [ ] **EMBED-04**: Shadow DOM sandbox blocks `window.open`, `window.top` navigation, popup creation, and `alert`/`confirm`/`prompt`
- [ ] **EMBED-05**: Shadow DOM sandbox prevents access to parent page cookies and localStorage
- [ ] **EMBED-06**: Proxy strips known ad/tracker scripts and domains from proxied content before serving
- [ ] **EMBED-07**: Proxy rewrites relative URLs in proxied content to route through the proxy (so sub-resources load correctly)
- [ ] **EMBED-08**: All proxied content served with strict CSP headers scoped to the sandbox context

## v2 Requirements

Deferred to future release. Tracked but not in current roadmap.

### Enhanced Sources

- **SRC-01**: Support scraping from additional subreddits or Discord channels
- **SRC-02**: User-reported stream quality ratings

### UI Enhancements

- **UI-01**: Real-time WebSocket push of stream health status changes
- **UI-02**: Stream quality indicator (resolution, bitrate if detectable)
- **UI-03**: Stream viewer count or popularity metric

### Security Hardening

- **SEC-01**: Ad-blocker filter list integration (uBlock Origin lists)
- **SEC-02**: JavaScript AST analysis for malicious patterns before allowing execution

## Out of Scope

| Feature | Reason |
|---------|--------|
| Database migration (SQLite/PostgreSQL) | File-based storage is sufficient for current scale |
| Multiple replica deployment | Single-user/small-group usage, single replica is fine |
| Mobile app | Web-only, responsive design sufficient |
| OAuth/social login | WebAuthn already works |
| Full browser automation (Puppeteer/Playwright) | Too heavy for stream validation; HTTP-based checks are sufficient |
| Video transcoding/re-streaming | Out of scope — we link to or proxy existing streams |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| SCRP-01 | Phase 1 | Pending |
| SCRP-02 | Phase 1 | Pending |
| SCRP-03 | Phase 1 | Pending |
| SCRP-04 | Phase 1 | Pending |
| HLTH-01 | Phase 2 | Pending |
| HLTH-02 | Phase 2 | Pending |
| HLTH-03 | Phase 2 | Pending |
| HLTH-04 | Phase 2 | Pending |
| HLTH-05 | Phase 2 | Pending |
| HLTH-06 | Phase 2 | Pending |
| HLTH-07 | Phase 2 | Pending |
| HLTH-08 | Phase 2 | Pending |
| HLTH-09 | Phase 2 | Pending |
| AUTO-01 | Phase 3 | Pending |
| AUTO-02 | Phase 3 | Pending |
| AUTO-03 | Phase 3 | Pending |
| EMBED-01 | Phase 4 | Pending |
| EMBED-02 | Phase 4 | Pending |
| EMBED-03 | Phase 5 | Pending |
| EMBED-04 | Phase 5 | Pending |
| EMBED-05 | Phase 5 | Pending |
| EMBED-06 | Phase 5 | Pending |
| EMBED-07 | Phase 5 | Pending |
| EMBED-08 | Phase 5 | Pending |

**Coverage:**
- v1 requirements: 24 total
- Mapped to phases: 24
- Unmapped: 0

---
*Requirements defined: 2026-02-17*
*Last updated: 2026-02-17 after roadmap creation*
