# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-23)

**Core value:** When an F1 session is live, users open one URL and immediately see working streams — no hunting for links.
**Current focus:** All 8 phases complete — deployed and verified

## Current Position

Phase: 8 of 8 (Multi-Stream Layout) — COMPLETE
Status: Deployed and verified at https://f1.viktorbarzin.me
Last activity: 2026-02-24 — All phases deployed, frontend routing fixed, full verification passed

Progress: [██████████] 100%

## Phase Completion Summary

| Phase | Name | Status | Image |
|-------|------|--------|-------|
| 1 | Infrastructure & Deployment | Complete | v2.0.1 |
| 2 | F1 Schedule Subsystem | Complete | v2.0.3 |
| 3 | Extractor Framework | Complete | v3.0.0 |
| 4 | Stream Health Checker | Complete | v5.0.0 |
| 5 | HLS Proxy & Relay | Complete | v5.0.0 |
| 6 | CDN Token Lifecycle | Complete | v5.0.0 |
| 7 | SvelteKit Frontend | Complete | v5.0.0 |
| 8 | Multi-Stream Layout | Complete | v5.0.0 |

## Verified Endpoints

- `/health` — 200 OK
- `/` — 200 (SvelteKit schedule page)
- `/watch` — 200 (multi-stream player)
- `/schedule` — 200 (24 races, 2026 season)
- `/streams` — 200 (3 demo streams)
- `/extractors` — 200
- `/streams/active` — 200
- `/proxy?url=...` — 200 (HLS m3u8 rewriting)
- `/relay?url=...` — streaming (chunked segment relay)

## Accumulated Context

### Decisions

- Custom per-site extractors over headless browser
- No authentication — security by obscurity
- Proxy streams through service for unified player
- APScheduler in-process (no Celery)
- Kaniko for in-cluster Docker builds (Docker Desktop unavailable)
- v5.0.0 tag to bypass pull-through cache (10.0.20.10 caches stale :latest)
- Catch-all FastAPI route for SvelteKit SPA (adapter-static generates {page}.html, not {page}/index.html)

### Known Issues

- Pull-through cache at 10.0.20.10 caches Docker tags aggressively — must use new tags to deploy updates
- Only demo extractor exists — real streaming site extractors need to be built
- Woodpecker CI webhook may not be configured for f1-stream builds

## Session Continuity

Last session: 2026-02-24
Stopped at: All 8 phases deployed and verified
Next steps: Add real streaming site extractors (Phase 3 expansion)
