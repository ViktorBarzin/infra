# Codebase Concerns

**Analysis Date:** 2026-02-17

## Tech Debt

**File-based JSON storage as primary data persistence:**
- Issue: All data (users, streams, sessions, scraped links) are stored as JSON files on disk with file-level locking. This is a fundamental scalability constraint.
- Files: `internal/store/store.go`, `internal/store/streams.go`, `internal/store/sessions.go`, `internal/store/users.go`, `internal/store/scraped.go`
- Impact:
  - Non-atomic multi-file operations (e.g., DeleteStream reads all streams, filters, writes back). Race conditions possible if two deletes happen simultaneously.
  - Entire file loaded into memory for any operation, even reads. With thousands of streams/sessions, this becomes slow and memory-inefficient.
  - Sessions file grows unbounded until manual cleanup (CleanExpiredSessions runs hourly). Could cause memory/disk pressure.
  - No transaction support, no rollback capability on failure.
- Fix approach: Migrate to a proper database (SQLite for simplicity, PostgreSQL for production). Keep JSON file for backup/export purposes only.

**In-memory WebAuthn ceremony session storage with no cleanup guarantee:**
- Issue: Registration and login ceremony session data stored in `Auth.regSessions` and `Auth.loginSessions` maps. Cleanup relies on goroutines that may not execute if server crashes.
- Files: `internal/auth/auth.go` (lines 27-29, 107-117, 230-239)
- Impact:
  - Memory leak on server restarts: orphaned sessions never cleaned up.
  - No recovery mechanism if goroutine misses cleanup window.
  - Session hijacking if an attacker can predict/guess the cleanup timing.
- Fix approach: Either move ceremony sessions to persistent store or use a time.AfterFunc with guaranteed cleanup (still risky). Better: use signed JWTs for ceremony state instead of server-side storage.

**Scraper loads entire scraped links list into memory on every scrape:**
- Issue: `Scraper.scrape()` loads all existing links, filters and deduplicates them, then rewrites entire file.
- Files: `internal/scraper/scraper.go` (lines 46-92)
- Impact: With thousands of links, each 15-minute scrape cycle causes a large memory spike and full file rewrite. Inefficient deduplication logic (O(n) map lookups on every new link).
- Fix approach: With database migration, use INSERT OR IGNORE / upsert patterns. For now, batch process links in chunks and use database indexes for deduplication.

**No input validation on URL lengths beyond basic checks:**
- Issue: URL length limited to 2048 chars in two places (`internal/server/server.go` line 153, `internal/proxy/proxy.go` line 72), but no validation of URL structure beyond "starts with http/https" and HTTPS-only in proxy.
- Files: `internal/server/server.go` (lines 146-160), `internal/proxy/proxy.go` (lines 54-80)
- Impact: Malformed URLs could bypass checks and cause unexpected behavior in downstream systems. User submission streams could contain typos/malware links.
- Fix approach: Use a proper URL parsing library with validation. Whitelist domains for stream submissions. Consider regex validation for known stream site patterns.

**Hardcoded default streams in main.go:**
- Issue: Default stream URLs are hardcoded and point to external streaming sites that may become unavailable, redirect, or change terms of service.
- Files: `main.go` (lines 100-123)
- Impact: If any of these URLs break, users get broken default content. Sites could shut down or get legal takedown notices. Application appears to endorse/support these sites.
- Fix approach: Move to configuration file. Make seeding optional. Add stream validation/health checks before serving. Consider removing entirely if this is a liability concern.

**Proxy strips CSP headers without replacement:**
- Issue: `internal/proxy/proxy.go` deliberately strips `X-Frame-Options` and CSP headers (line 123) to allow iframe-based proxying. No security headers added back.
- Files: `internal/proxy/proxy.go` (lines 121-125)
- Impact: Proxied content loses all origin security protections. Could allow downstream attacks to run XSS, clickjacking, etc. in the proxy context. Injected `<base>` tag doesn't prevent all attacks.
- Fix approach: Add back a strict CSP policy scoped to the proxy origin. Implement iframe sandbox attributes. Add additional security headers (X-Content-Type-Options: nosniff, etc.).

## Security Considerations

**Authentication ceremony session fixation vulnerability:**
- Risk: Username used as session key for WebAuthn ceremonies (`Auth.BeginRegistration`, `Auth.BeginLogin`). Attacker could start ceremony for victim's account, then victim continues from attacker's session state.
- Files: `internal/auth/auth.go` (lines 107-108, 230-231)
- Current mitigation: None. Ceremony session stored in-memory and deleted after 5 minutes, but no CSRF token or state validation.
- Recommendations: Use cryptographically random state tokens for ceremony sessions instead of username. Store state in secure HTTP-only cookies or database. Validate state on finish.

**Rate limiting per-IP but no account lockout for failed authentication:**
- Risk: Brute force attacks on specific usernames are possible. Attacker can try many passwords (using different IPs) against a single account without consequence.
- Files: `internal/proxy/proxy.go` implements rate limiting (per-IP token bucket), but no equivalent exists for auth endpoints (`internal/auth/auth.go`).
- Current mitigation: WebAuthn makes guessing harder (passkeys), but early attack surface (BeginLogin endpoint) has no protection. Leaked user list could enable targeted attacks.
- Recommendations: Add per-username failure tracking. Lock account after N failed attempts. Add exponential backoff. Require captcha after threshold.

**CORS Origin validation incomplete:**
- Risk: `OriginCheck` middleware in `internal/server/middleware.go` (lines 71-93) only checks on non-GET requests. GET requests can still trigger state-changing operations (e.g., visiting a crafted link that proxies through the app).
- Files: `internal/server/middleware.go` (lines 74)
- Current mitigation: Proxy request uses query param, but no SameSite cookie attribute on proxy endpoint (only on session cookie).
- Recommendations: Require Origin header on all mutation requests. Consider using POST for scrape trigger. Add X-CSRF-Token validation.

**Admin user initialization has race condition:**
- Risk: First user to register becomes admin if `ADMIN_USERNAME` not set. Two concurrent registration requests could both see 0 users and both become admin.
- Files: `internal/auth/auth.go` (lines 83-91)
- Current mitigation: Relies on file-level locking in store operations, but store operations are done after the check (line 121), not atomic.
- Recommendations: Move first-user-is-admin logic into CreateUser transaction, or seed admin during initialization phase before accepting requests.

**Session token stored in http-only cookie but not marked Secure in non-HTTPS:**
- Risk: Cookie marked `Secure: r.TLS != nil` (line 187, 300). In development or non-HTTPS deployments, session token sent over plaintext HTTP.
- Files: `internal/auth/auth.go` (lines 187, 300)
- Current mitigation: None for non-HTTPS. Relies on deployment to enforce HTTPS.
- Recommendations: Always set Secure=true. Force HTTPS in production via HSTS header. Log warning if TLS is nil.

**Proxy does not validate Content-Type before injecting `<base>` tag:**
- Risk: Non-HTML responses (PDFs, images, binaries) could be corrupted by injecting `<base>` tag. Base64 encoded binary data could break.
- Files: `internal/proxy/proxy.go` (lines 104-119)
- Current mitigation: 5MB body size limit, but no content-type validation.
- Recommendations: Check Content-Type header before modification. Skip injection for non-HTML types. Use proper HTML parsing (e.g., golang.org/x/net/html) instead of string manipulation.

## Performance Bottlenecks

**Scraper Reddit parsing with inefficient comment recursion:**
- Problem: `walkComments` in `internal/scraper/reddit.go` (lines 245-260) recursively walks comment trees using JSON unmarshaling in each recursion level. Could cause O(n^2) behavior on deep comment threads.
- Files: `internal/scraper/reddit.go` (lines 245-260, 132-142)
- Cause: Each comment reply is unmarshaled separately. For a thread with 1000 nested replies, this could create 1000 unmarshaling operations.
- Improvement path: Pre-flatten comment tree or use iterative traversal instead of recursion. Cache unmarshaled comments during initial fetch.

**O(n) lookups on every store operation:**
- Problem: All store methods (GetUserByName, GetUserByID, FindStream by ID) iterate through entire in-memory list.
- Files: `internal/store/users.go` (lines 21-49), `internal/store/streams.go` (lines 12-52)
- Cause: File-based storage forces full-file loads. Even with caching, no indexing.
- Improvement path: With database migration, use indexed lookups. For now, maintain in-process cache with invalidation on updates.

**Rate limiter token bucket not garbage collected properly:**
- Problem: Buckets for old IPs are deleted every 10 minutes (bucketCleanup), but inactive users' buckets accumulate until cleanup cycle.
- Files: `internal/proxy/proxy.go` (lines 170-181)
- Cause: Cleanup is reactive, not triggered on write. High-traffic scenarios could have thousands of stale buckets in memory.
- Improvement path: Use sync.Map for lock-free reads. Implement heap-based cleanup timer per bucket instead of global interval.

**Entire streams/sessions list rewritten on every add/delete:**
- Problem: Adding one stream requires reading all streams, appending, and rewriting entire file. Deleting a session does the same.
- Files: `internal/store/streams.go` (lines 54-78, 80-103), `internal/store/sessions.go` (lines 22-44, 61-81)
- Cause: Atomic write pattern (writeJSON uses temp-file-then-rename), but forces full serialization.
- Improvement path: Migrate to database with transaction support. Implement write-ahead logging if staying with files.

## Fragile Areas

**Proxy string-based HTML manipulation is fragile:**
- Files: `internal/proxy/proxy.go` (lines 107-119)
- Why fragile: Uses string.Index to find `<head>` and `<html>` tags with string.ToLower comparisons. Cases like `<HEAD>` would be missed. Malformed HTML (missing closing tags, nested structures) could place `<base>` tag in wrong location.
- Safe modification: Use golang.org/x/net/html parser. Insert `<base>` into head node properly. Handle edge cases (no head, multiple heads, xhtml).
- Test coverage: No tests for proxy HTML injection logic. Edge cases untested.

**Auth ceremony cleanup relies on goroutines:**
- Files: `internal/auth/auth.go` (lines 112-117, 234-239)
- Why fragile: If goroutine is blocked or delayed, cleanup doesn't happen. No guarantee cleanup runs at correct time. Server crash loses all in-flight ceremonies.
- Safe modification: Use context deadlines instead of sleep timers. Implement cleanup on FinishRegistration/FinishLogin regardless of goroutine. Store ceremonies in database with TTL.
- Test coverage: No tests for ceremony timeout behavior. Hard to test goroutine cleanup timing.

**DeleteStream and related operations use string.Contains for error classification:**
- Files: `internal/server/server.go` (lines 196-203)
- Why fragile: Error messages must contain specific strings ("not authorized", "not found") for proper HTTP status mapping. Changing error text breaks error handling.
- Safe modification: Use error types (custom errors or error wrapping with errors.Is/As). Map error types to status codes centrally.
- Test coverage: No tests for error status code mapping.

**Scraper is single-threaded with mutex but TriggerScrape starts new goroutine:**
- Files: `internal/scraper/scraper.go` (lines 42-44, 46-92)
- Why fragile: Calling TriggerScrape while scrape() is running (locked) will queue a second scrape. If scrapes take >15 minutes, queue grows. No bounds on concurrent scrapes.
- Safe modification: Use atomic flag to prevent concurrent scrapes. Queue only one pending scrape. Timeout long-running scrapes.
- Test coverage: No tests for concurrent scrape behavior or queue limits.

**Admin check depends on user count atomicity:**
- Files: `internal/auth/auth.go` (lines 83-91)
- Why fragile: Check user count, then create user are separate operations. Two concurrent registrations both see count=0, both get admin. Later operation fails due to username uniqueness check, but by then both claimed to be admin.
- Safe modification: Move atomicity into CreateUser. Use database transaction.
- Test coverage: No concurrency tests for admin initialization.

## Scaling Limits

**All data files live on single filesystem:**
- Current capacity: Depends on disk size. Assuming 1GB available, JSON files with generous spacing could hold ~100k streams, users, or sessions before performance degrades.
- Limit: At 10k active users with 5 sessions each (50k sessions), sessions.json alone is >50MB uncompressed. Each read loads entire file.
- Scaling path: Migrate to database. Use SQLite for single-node, PostgreSQL for distributed. Implement sharding for sessions by user_id.

**In-memory rate limit buckets per IP:**
- Current capacity: ~100k unique IPs can be tracked before memory pressure (each bucket ~48 bytes).
- Limit: Behind a proxy/load balancer, all traffic appears from proxy IP, making per-IP limiting useless. Map grows indefinitely per proxy.
- Scaling path: Move rate limiting to reverse proxy/load balancer layer (nginx, Envoy). Or, extract real IP from X-Forwarded-For more carefully (currently does this, but assumes trust).

**Scraper single-threaded, only hits one subreddit:**
- Current capacity: 25 posts per run * 15-min interval = 100 posts/hour. Each post processes comments once. Total throughput ~1000-5000 URLs/hour depending on post depth.
- Limit: If stream demand increases or multiple subreddits need scraping, single scraper becomes bottleneck. No parallelism.
- Scaling path: Implement scraper pool. Scrape multiple subreddits in parallel. Move scraper to separate service. Implement distributed job queue.

**WebAuthn session storage grows unbounded until server restart:**
- Current capacity: Each ceremony session is ~1KB. 1000 concurrent registrations = 1MB. 100k in-flight = 100MB.
- Limit: Memory exhaustion if registrations are started but not finished (or attacker starts many ceremonies).
- Scaling path: Use database for ceremony sessions. Implement hard timeout (e.g., 5 min) enforced by scheduled cleanup task. Set max concurrent ceremonies.

## Dependencies at Risk

**go-webauthn/webauthn v0.15.0:**
- Risk: Security library. May have vulnerabilities. Check for updates regularly.
- Impact: Passkey authentication could be compromised if library has bugs.
- Migration plan: Keep updated. Monitor GitHub releases. Test updates before deploying.

**Hardcoded subreddit URL (reddit.com API):**
- Risk: Reddit API could change, add authentication requirements, or shut down /r/motorsportsstreams2 community.
- Impact: Scraper stops working entirely. No fallback stream sources.
- Migration plan: Implement abstraction for stream sources. Support multiple scraper backends (Reddit, Discord, Twitter, etc.). Add health checks for scraper endpoints.

## Test Coverage Gaps

**No tests for HTTP error handling:**
- What's not tested: Error status code mapping, error response formatting, error logging.
- Files: `internal/server/server.go` (all handlers), `internal/auth/auth.go` (all endpoints)
- Risk: Error responses could be inconsistent or leaky (exposing internal details). Status codes could be wrong.
- Priority: High

**No tests for concurrent store operations:**
- What's not tested: Race conditions in add/delete/update. Concurrent reads while write in progress.
- Files: `internal/store/streams.go`, `internal/store/sessions.go`, `internal/store/users.go`
- Risk: Data corruption or loss under load. Auth bypass if race condition allows duplicate users.
- Priority: High

**No tests for WebAuthn ceremony timeouts:**
- What's not tested: Behavior when ceremony session expires. Cleanup of orphaned sessions.
- Files: `internal/auth/auth.go` (BeginRegistration, FinishRegistration, BeginLogin, FinishLogin)
- Risk: Session fixation, orphaned memory, unexpected behavior on retry.
- Priority: Medium

**No tests for proxy HTML injection:**
- What's not tested: Edge cases (malformed HTML, no head tag, nested structures). Security implications (XSS prevention, CSP).
- Files: `internal/proxy/proxy.go` (ServeHTTP)
- Risk: Injected tags could be placed incorrectly. Proxied content could break. Security headers could be ineffective.
- Priority: Medium

**No tests for rate limiter token bucket algorithm:**
- What's not tested: Burst capacity behavior, refill rate, edge cases (high request volume, time skew).
- Files: `internal/proxy/proxy.go` (allowRequest, cleanBuckets)
- Risk: Rate limiting could be too strict or too lenient. Cleanup could fail to run.
- Priority: Medium

**No tests for admin initialization logic:**
- What's not tested: First user gets admin flag. Edge cases with concurrent registrations. Behavior when ADMIN_USERNAME is set.
- Files: `internal/auth/auth.go` (BeginRegistration, lines 83-91)
- Risk: Non-admin user gets admin flag (privilege escalation). Two admins created unexpectedly.
- Priority: High

**No integration tests for full auth flow:**
- What's not tested: Complete registration + login + logout cycle. Error recovery. Session expiration.
- Files: All of `internal/auth/auth.go` and `internal/server/server.go` auth endpoints.
- Risk: Subtle bugs in ceremony sequencing. Auth logic could break without being detected.
- Priority: High

**No tests for scraper Reddit parsing:**
- What's not tested: Comment tree recursion. URL extraction. F1 keyword matching. Deduplication logic.
- Files: `internal/scraper/reddit.go`
- Risk: Scraper could miss streams, extract bad URLs, or fail on unexpected Reddit response format.
- Priority: Medium

---

*Concerns audit: 2026-02-17*
