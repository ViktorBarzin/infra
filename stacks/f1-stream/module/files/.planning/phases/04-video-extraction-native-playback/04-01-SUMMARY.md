---
phase: 04-video-extraction-native-playback
plan: 01
subsystem: api
tags: [html-parsing, video-extraction, hls, dash, golang-x-net]

# Dependency graph
requires:
  - phase: 02-health-check-infrastructure
    provides: HTTP client patterns (timeout, redirect limit, user-agent)
  - phase: 03-auto-publish-pipeline
    provides: Store with stream lookup (LoadStreams)
provides:
  - Video source extractor package (internal/extractor)
  - GET /api/streams/{id}/extract endpoint
  - VideoSource struct with URL and type classification
affects: [04-02, frontend-video-player, native-playback]

# Tech tracking
tech-stack:
  added: [golang.org/x/net/html]
  patterns: [DOM tree walking, regex script extraction, content-type detection]

key-files:
  created: [internal/extractor/extractor.go]
  modified: [internal/server/server.go, go.mod, go.sum]

key-decisions:
  - "DOM parsing with golang.org/x/net/html for structured element extraction"
  - "Regex patterns for script tag video URL extraction (HLS, DASH, JWPlayer, video.js, hls.js)"
  - "Priority ordering: HLS > DASH > MP4 > WebM for frontend source selection"
  - "5-minute cache (Cache-Control: public, max-age=300) to reduce upstream load"
  - "Empty sources array (not error) when no video found, to distinguish from fetch failures"

patterns-established:
  - "Extractor pattern: multiple strategies (DOM + regex) with deduplication and priority sorting"
  - "Direct content-type bypass: skip HTML parsing when response is already a video type"

requirements-completed: [EMBED-01]

# Metrics
duration: 3min
completed: 2026-02-17
---

# Phase 04 Plan 01: Video Source Extractor Summary

**HTML video source extractor with DOM parsing and script regex extraction, exposed via GET /api/streams/{id}/extract endpoint with 5-minute caching**

## Performance

- **Duration:** 3 min
- **Started:** 2026-02-17T21:42:49Z
- **Completed:** 2026-02-17T21:46:03Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- Created video source extractor package that finds HLS, DASH, MP4, WebM URLs from HTML pages
- DOM parsing extracts URLs from `<video>`, `<source>`, and `<iframe>` elements
- Regex extraction finds video URLs from script tags including JWPlayer, video.js, and hls.js patterns
- API endpoint returns extracted sources with type classification and priority ordering
- Direct video content-type detection bypasses HTML parsing for efficiency

## Task Commits

Each task was committed atomically:

1. **Task 1: Create video source extractor package** - `74410e2` (feat)
2. **Task 2: Add extract API endpoint to server** - `bc9614e` (feat)

**Plan metadata:** (pending final docs commit)

## Files Created/Modified
- `internal/extractor/extractor.go` - Video source extraction from HTML pages with DOM and regex strategies
- `internal/server/server.go` - Added /api/streams/{id}/extract endpoint with cache headers
- `go.mod` - Added golang.org/x/net dependency
- `go.sum` - Updated dependency checksums

## Decisions Made
- Used golang.org/x/net/html for DOM parsing (consistent with plan, deferred from Phase 2 per project decisions)
- Implemented dual extraction strategy: structured DOM walking + regex script parsing for maximum coverage
- Priority ordering (HLS > DASH > MP4 > WebM) helps frontend pick best playback option automatically
- 5-minute Cache-Control header prevents hammering upstream sites when multiple users view same stream
- Return empty sources array (not error) when no video found -- caller can distinguish "no video" from "fetch failed"
- 15-second timeout and 3-redirect limit matching existing proxy/scraper patterns

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
- Go module cache permission error on default GOPATH; resolved by using temporary GOMODCACHE/GOPATH for build commands. This is a sandbox environment constraint, not a code issue.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Extractor package ready for Plan 02 (frontend native video player)
- API endpoint returns structured JSON that frontend can consume to initialize HTML5 video playback
- HLS/DASH sources will need hls.js/dash.js on the frontend for browser playback

---
*Phase: 04-video-extraction-native-playback*
*Completed: 2026-02-17*

## Self-Check: PASSED

- FOUND: internal/extractor/extractor.go
- FOUND: internal/server/server.go
- FOUND: 04-01-SUMMARY.md
- FOUND: commit 74410e2
- FOUND: commit bc9614e
