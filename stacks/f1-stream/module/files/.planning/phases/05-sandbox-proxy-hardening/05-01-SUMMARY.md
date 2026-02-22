---
phase: 05-sandbox-proxy-hardening
plan: 01
subsystem: proxy
tags: [html-sanitizer, csp, ad-blocker, url-rewrite, golang-x-net-html]

# Dependency graph
requires:
  - phase: 04-video-extraction-native-playback
    provides: "Proxy infrastructure and html parsing with golang.org/x/net/html"
provides:
  - "HTML sanitizer that strips ad/tracker scripts from proxied content"
  - "Ad/tracker domain blocklist with 50+ entries and parent-domain lookup"
  - "/proxy/sandbox endpoint serving sanitized HTML with strict CSP"
  - "Relative URL rewriting through proxy for sub-resources"
affects: [05-02-PLAN, frontend-sandbox]

# Tech tracking
tech-stack:
  added: []
  patterns: [DOM-walking sanitizer, domain blocklist with parent lookup, CSP header injection]

key-files:
  created:
    - internal/proxy/sanitize.go
    - internal/proxy/blocklist.go
  modified:
    - internal/proxy/proxy.go
    - internal/server/server.go

key-decisions:
  - "50+ ad/tracker domains in blocklist with parent-domain walk-up matching"
  - "Inline scripts kept (needed for video players), blocked scripts removed by domain"
  - "CSP allows img/media/connect broadly since video sources come from arbitrary origins"
  - "Non-HTML sub-resources proxied as-is with CSP headers"

patterns-established:
  - "DOM-walking sanitizer pattern: collect nodes to remove, then detach (avoid mutation during walk)"
  - "Blocklist with parent-domain lookup: check host then walk up domain labels"

requirements-completed: [EMBED-06, EMBED-07, EMBED-08]

# Metrics
duration: 2min
completed: 2026-02-17
---

# Phase 5 Plan 1: Sandbox Proxy Hardening Summary

**Backend proxy sanitizer stripping 50+ ad/tracker domains, rewriting relative URLs through /proxy/sandbox, and enforcing strict CSP headers**

## Performance

- **Duration:** 2 min
- **Started:** 2026-02-17T22:00:20Z
- **Completed:** 2026-02-17T22:02:30Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments
- HTML sanitizer that walks DOM tree removing scripts, links, images, iframes, objects, and embeds from blocked ad/tracker domains
- Domain blocklist with 50+ entries and parent-domain walk-up matching (e.g., ads.doubleclick.net matches doubleclick.net)
- New `/proxy/sandbox` endpoint serving sanitized HTML with strict CSP headers
- Relative and protocol-relative URL rewriting through the proxy for sub-resources
- Non-HTML content (CSS, images, fonts) proxied as-is with CSP headers applied

## Task Commits

Each task was committed atomically:

1. **Task 1: Create HTML sanitizer with ad/tracker stripping and URL rewriting** - `c0d545e` (feat)
2. **Task 2: Add ServeSandbox endpoint with CSP headers and wire route** - `322ff4d` (feat)

## Files Created/Modified
- `internal/proxy/blocklist.go` - Ad/tracker domain blocklist with 50+ domains and IsBlockedDomain with parent-domain lookup
- `internal/proxy/sanitize.go` - HTML sanitizer: strips blocked elements, rewrites relative URLs through proxy
- `internal/proxy/proxy.go` - ServeSandbox endpoint with CSP headers, HTML parsing, and sanitization
- `internal/server/server.go` - Route registration for GET /proxy/sandbox

## Decisions Made
- Kept inline scripts (no src attribute) because video players need them; only strip scripts with blocked-domain src
- CSP policy allows `script-src 'unsafe-inline'` for player compatibility while blocking frames and objects
- Images, media, and connect-src allowed broadly (`*`) since video sources come from arbitrary CDN origins
- Non-HTML resources get CSP headers but no body transformation (CSS/images/fonts pass through)
- Parent-domain walk-up in blocklist: blocking "example.com" also blocks "ads.example.com" and deeper subdomains

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Sandbox proxy endpoint ready for frontend shadow DOM integration (05-02)
- `/proxy/sandbox?url=...` serves clean HTML suitable for shadow DOM injection
- CSP headers prevent iframe embedding and object injection from sanitized content

---
*Phase: 05-sandbox-proxy-hardening*
*Completed: 2026-02-17*

## Self-Check: PASSED

All files verified present. All commits verified in history.
