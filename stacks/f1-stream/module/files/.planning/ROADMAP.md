# Roadmap: F1 Stream

## Overview

This roadmap delivers server-side stream quality assurance and secure viewing. First, the scraper learns to validate that extracted URLs actually contain video content. Then a background health checker continuously monitors all streams. These combine into an auto-publish pipeline that surfaces good streams and hides dead ones without admin intervention. Finally, secure embedding replaces raw iframes with native video playback where possible and a hardened sandbox fallback for everything else.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [ ] **Phase 1: Scraper Validation** - Scraper validates extracted URLs contain video/player content before saving
- [ ] **Phase 2: Health Check Infrastructure** - Background service continuously monitors stream health and persists status
- [ ] **Phase 3: Auto-publish Pipeline** - Healthy scraped streams auto-publish; dead streams auto-hide
- [ ] **Phase 4: Video Extraction and Native Playback** - Extract direct video sources and play them in a native HTML5 player
- [ ] **Phase 5: Sandbox and Proxy Hardening** - Fallback rendering in a sandboxed shadow DOM with ad stripping and strict CSP

## Phase Details

### Phase 1: Scraper Validation
**Goal**: Scraped URLs are verified to contain actual video/player content before being stored, eliminating junk links at the source
**Depends on**: Nothing (extends existing scraper)
**Requirements**: SCRP-01, SCRP-02, SCRP-03, SCRP-04
**Success Criteria** (what must be TRUE):
  1. Scraper still discovers F1-related posts from Reddit using keyword filtering (existing behavior preserved)
  2. Each extracted URL is proxy-fetched and inspected for video/player content markers (video tags, HLS/DASH manifests, player libraries)
  3. URLs without video content markers are discarded and do not appear in scraped.json
  4. Validation respects a configurable timeout so slow sites do not block the scrape cycle
**Plans**: 1 plan

Plans:
- [ ] 01-01-PLAN.md — Add URL validation with video marker detection to scraper pipeline

### Phase 2: Health Check Infrastructure
**Goal**: All known streams are continuously monitored for health, with status persisted and unhealthy streams hidden from users
**Depends on**: Phase 1 (reuses content validation logic from scraper validation)
**Requirements**: HLTH-01, HLTH-02, HLTH-03, HLTH-04, HLTH-05, HLTH-06, HLTH-07, HLTH-08, HLTH-09
**Success Criteria** (what must be TRUE):
  1. A background service checks every known stream (scraped and user-submitted) on a regular interval that defaults to 5 minutes and is configurable via environment variable
  2. Each check performs HTTP reachability first, then proxy-fetches the page to verify video/player content markers
  3. Each stream's health state (consecutive failure count, last check time, healthy/unhealthy flag) is persisted across restarts
  4. A stream is hidden from the public streams page after 5 consecutive check failures, and restored if it later passes a check
  5. Health check timeout per stream is configurable
**Plans**: 2 plans

Plans:
- [ ] 02-01-PLAN.md — HealthState model, store persistence, export HasVideoContent, create HealthChecker service
- [ ] 02-02-PLAN.md — Wire health checker in main.go, filter unhealthy streams from public API

### Phase 3: Auto-publish Pipeline
**Goal**: Scraped streams that pass validation and health checks appear on the public page automatically; dead streams disappear without admin action
**Depends on**: Phase 1, Phase 2
**Requirements**: AUTO-01, AUTO-02, AUTO-03
**Success Criteria** (what must be TRUE):
  1. A scraped stream that passes scraper validation and its first health check is visible on the public streams page without any admin approval
  2. A stream marked unhealthy (5 consecutive failures) is no longer visible on the public page, with no admin intervention required
  3. Auto-published streams are distinguishable from user-submitted streams in the data model (source field tracks origin)
**Plans**: 1 plan

Plans:
- [ ] 03-01-PLAN.md — Add Source field to Stream model, create PublishScrapedStream, wire scraper auto-publish

### Phase 4: Video Extraction and Native Playback
**Goal**: When a stream URL contains an extractable video source, users watch it in a clean native HTML5 player instead of loading the third-party page
**Depends on**: Nothing (independent of phases 1-3; can be built in parallel but ordered here for delivery focus)
**Requirements**: EMBED-01, EMBED-02
**Success Criteria** (what must be TRUE):
  1. The proxy can extract direct video source URLs (HLS .m3u8, DASH .mpd, direct MP4/WebM, or embedded player source attributes) from a stream page
  2. When a direct video source is found, the user sees a minimal HTML5 video player on the app's own page playing the stream without loading the original third-party page
**Plans**: 2 plans

Plans:
- [ ] 04-01-PLAN.md — Backend video source extractor package and API endpoint
- [ ] 04-02-PLAN.md — Frontend native HTML5 video player with HLS.js and iframe fallback

### Phase 5: Sandbox and Proxy Hardening
**Goal**: When direct video extraction fails, the proxied page is rendered safely in a sandbox that blocks popups, ads, and access to the parent page
**Depends on**: Phase 4 (this is the fallback path when extraction fails)
**Requirements**: EMBED-03, EMBED-04, EMBED-05, EMBED-06, EMBED-07, EMBED-08
**Success Criteria** (what must be TRUE):
  1. When direct video extraction fails, the full proxied page renders inside a shadow DOM sandbox on the app's page
  2. The sandbox blocks window.open, top-frame navigation, popup creation, and alert/confirm/prompt dialogs
  3. The sandbox prevents the proxied content from accessing parent page cookies and localStorage
  4. Known ad/tracker scripts and domains are stripped from proxied content before serving, and relative URLs are rewritten to route through the proxy
  5. All proxied content is served with strict CSP headers scoped to the sandbox context
**Plans**: 2 plans

Plans:
- [ ] 05-01-PLAN.md — Backend proxy hardening: HTML sanitizer with ad/tracker stripping, URL rewriting, and CSP headers
- [ ] 05-02-PLAN.md — Frontend shadow DOM sandbox replacing iframe fallback with API overrides

## Progress

**Execution Order:**
Phases execute in numeric order: 1 -> 2 -> 3 -> 4 -> 5

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Scraper Validation | 0/1 | Planned | - |
| 2. Health Check Infrastructure | 0/2 | Planned | - |
| 3. Auto-publish Pipeline | 0/1 | Planned | - |
| 4. Video Extraction and Native Playback | 0/2 | Planned | - |
| 5. Sandbox and Proxy Hardening | 0/2 | Not started | - |
