# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-17)

**Core value:** Users can find working F1 streams quickly -- the app automatically discovers, validates, and surfaces healthy streams while removing dead ones.
**Current focus:** Phase 5: Sandbox Proxy Hardening (complete)

## Current Position

Phase: 5 of 5 (Sandbox Proxy Hardening)
Plan: 2 of 2 in current phase (complete)
Status: ALL PHASES COMPLETE -- project finished
Last activity: 2026-02-17 -- Completed 05-02 frontend shadow DOM sandbox

Progress: [██████████] 100%

## Performance Metrics

**Velocity:**
- Total plans completed: 8
- Average duration: 2.1min
- Total execution time: 0.28 hours

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 01-scraper-validation | 1 | 3min | 3min |
| 02-health-check-infrastructure | 2 | 4min | 2min |
| 03-auto-publish-pipeline | 1 | 2min | 2min |
| 04-video-extraction-native-playback | 2 | 5min | 2.5min |
| 05-sandbox-proxy-hardening | 2 | 3min | 1.5min |

**Recent Trend:**
- Last 5 plans: 2min, 3min, 2min, 2min, 1min
- Trend: Stable

*Updated after each plan completion*

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- Server-side health checks chosen over client-only (client can't inspect CORS responses)
- 5 consecutive failures threshold to avoid flapping
- Auto-publish for scraped streams that pass health check (health check is the quality gate)
- 5-minute health check interval (freshness vs load balance)
- String matching over DOM parsing for video detection (DOM reserved for Phase 4)
- 2MB body limit for HTML inspection to prevent memory issues
- 3 redirect limit to avoid infinite redirect chains on stream sites
- HealthMap reads file without lock to avoid deadlock from cross-lock scenarios
- Single HasVideoContent call covers both reachability and content checks
- Orphaned health state entries pruned each cycle to prevent unbounded file growth
- URLs not in health map assumed healthy to prevent new streams disappearing before first check
- HealthMap called within streamsMu/scrapedMu read locks safely via lock-free file read
- Source field uses string values (user/system/scraped) for readability over int enum
- PublishScrapedStream deduplicates by exact URL match; normalized matching stays in scraper layer
- Auto-publish iterates all validated links each cycle; deduplication makes repeat calls no-ops
- DOM parsing with golang.org/x/net/html for structured video source extraction (Phase 4)
- Dual extraction strategy: DOM walking + regex script parsing for maximum video URL coverage
- Priority ordering HLS > DASH > MP4 > WebM for frontend source selection
- 5-minute cache on extract endpoint to reduce upstream load
- Empty sources array (not error) when no video found to distinguish from fetch failures
- HLS.js loaded from jsDelivr CDN to avoid bundling complexity
- Extraction runs async after card render -- progressive enhancement with shadow DOM sandbox fallback
- DASH sources fall back to shadow DOM sandbox (dash.js too heavy for current scope)
- Silent console.log on extraction failure -- no user-facing errors for extraction issues
- 50+ ad/tracker domains in blocklist with parent-domain walk-up matching
- Inline scripts kept for video players; blocked scripts removed by domain
- CSP allows img/media/connect broadly since video sources come from arbitrary origins
- Non-HTML sub-resources proxied as-is with CSP headers
- Closed shadow DOM mode prevents external JS from accessing shadow root
- Script element created via createElement for execution in shadow DOM (innerHTML scripts don't execute)
- Direct link fallback when sandbox proxy fetch fails rather than broken state

### Pending Todos

None yet.

### Blockers/Concerns

None yet.

## Session Continuity

Last session: 2026-02-17
Stopped at: Completed 05-02-PLAN.md (frontend shadow DOM sandbox) -- ALL PHASES COMPLETE
Resume file: None
