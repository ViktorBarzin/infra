# Architecture

**Analysis Date:** 2026-02-17

## Pattern Overview

**Overall:** Layered monolithic service with clear separation between HTTP API layer, business logic, and persistent storage layer.

**Key Characteristics:**
- Single Go binary serving both API and static frontend
- File-based JSON persistence (no database)
- Modular internal packages for distinct concerns
- WebAuthn-based passwordless authentication
- Background scraper for content aggregation
- Rate-limited proxy service

## Layers

**HTTP Handler Layer:**
- Purpose: Accept and route HTTP requests, apply middleware, respond to clients
- Location: `internal/server/`
- Contains: Route registration, handler functions, middleware chains
- Depends on: Auth, Store, Proxy, Scraper packages
- Used by: HTTP clients (browser, mobile)

**Authentication & Authorization Layer:**
- Purpose: Manage user registration, login, sessions, and permission checks
- Location: `internal/auth/`
- Contains: WebAuthn ceremony implementations, session management, context helpers
- Depends on: Store, go-webauthn library
- Used by: Server middleware and handlers

**Business Logic Layer:**
- Purpose: Core domain operations (stream management, scraping, proxying)
- Location: `internal/scraper/`, `internal/proxy/`
- Contains: Scraper service (Reddit polling), Proxy service (content fetching with rate limiting)
- Depends on: Store for persistence
- Used by: Server, main entry point for orchestration

**Data Model Layer:**
- Purpose: Define domain types and interfaces
- Location: `internal/models/models.go`
- Contains: `User`, `Stream`, `ScrapedLink`, `Session` types
- Depends on: External WebAuthn library for credential types
- Used by: All layers

**Persistence Layer:**
- Purpose: Provide file-based storage abstraction
- Location: `internal/store/`
- Contains: JSON read/write helpers, file-based storage per entity type (streams, users, sessions, scraped links)
- Depends on: Models, filesystem
- Used by: All business logic layers

## Data Flow

**Stream Submission Flow:**

1. Client submits stream URL and title via `POST /api/streams`
2. Server handler validates URL format and length
3. Optional: If authenticated user, stream marked as unpublished; if anonymous, marked as published
4. Stream stored via `Store.AddStream()` which reads current `streams.json`, appends new stream, writes atomically
5. Response returned with stream metadata

**Authentication Flow (WebAuthn):**

1. User initiates registration with `POST /api/auth/register/begin` sending username
2. Server validates username format, checks uniqueness, creates temporary user
3. Server generates WebAuthn registration options via go-webauthn library
4. Server stores session data in memory with 5-minute expiry
5. Client performs attestation ceremony, sends credential via `POST /api/auth/register/finish?username=...`
6. Server retrieves in-memory session, validates with go-webauthn
7. Credential appended to user in `users.json`
8. Session token created in `sessions.json`, set as HttpOnly cookie

**Scraper Flow:**

1. Scraper runs on timer (default 15 minutes) or on manual trigger
2. Calls `scrapeReddit()` to poll r/motorsportsstreams2 new posts
3. Extracts URLs using regex, filters by F1-related keywords
4. Merges with existing `scraped.json`, deduplicating by normalized URL
5. Writes updated list atomically
6. Stale entries cleaned up, active ones returned via `GET /api/scraped`

**Proxy Flow:**

1. Client requests `GET /proxy?url=https://...`
2. Server validates URL scheme (must be HTTPS), length, and target is not private IP
3. Applies rate limiting via token bucket per client IP
4. Fetches URL with timeout, limits response body to 5MB
5. Injects `<base>` tag into HTML response for relative URL resolution
6. Strips X-Frame-Options and CSP headers to allow iframe embedding
7. Returns modified content

**Admin Approval Flow:**

1. Anonymous streams created with `Published: false`
2. Admin views all streams via `GET /api/admin/streams`
3. Admin toggles publication status via `PUT /api/streams/{id}/publish`
4. Published streams visible in `GET /api/streams/public`

**State Management:**

- **User Sessions:** In-memory WebAuthn ceremony sessions (5-minute TTL), persistent sessions in `sessions.json` with configurable TTL
- **Streams:** Fully loaded into memory from `streams.json` on each read/write, entire file rewritten atomically
- **Scraped Links:** Similar full-file pattern, deduplicated during scrape merge
- **Users:** Fully loaded per query, updated atomically per write
- **Cleanup:** Hourly cleanup of expired sessions via background goroutine

## Key Abstractions

**Store Interface (implicit):**
- Purpose: Encapsulate all file-based persistence operations
- Examples: `store.AddStream()`, `store.GetUserByName()`, `store.CreateSession()`
- Pattern: Each entity type has dedicated file; reads are lock-protected; writes are atomic (temp-file-then-rename)

**Auth Middleware Chain:**
- Purpose: Extract and validate user from session cookie, inject into request context
- Examples: `AuthMiddleware()`, `RequireAuth()`, `RequireAdmin()`
- Pattern: Composable handler functions that wrap next handler

**Scraper Service:**
- Purpose: Periodically fetch and aggregate content from external sources
- Examples: Background goroutine running on interval, triggered scrape
- Pattern: Mutex-protected scrape operations to prevent concurrent executions

**Proxy Handler:**
- Purpose: Fetch external content safely with rate limiting and framing bypass
- Examples: URL validation, private IP blocking, rate limiting per IP, HTML base tag injection
- Pattern: Implements `http.Handler` interface, maintains per-IP token bucket state

## Entry Points

**HTTP Server (`main.go`):**
- Location: `main.go`
- Triggers: Process start
- Responsibilities: Initialize all services, configure routes, handle graceful shutdown on SIGTERM/SIGINT

**Handler Routes (`internal/server/server.go`):**
- Location: `internal/server/server.go:registerRoutes()`
- Pattern: All routes defined in single function, middleware applied uniformly
- Public endpoints: Health, public streams, public scraped links
- Authenticated endpoints: Personal streams, submit stream, delete stream
- Admin endpoints: All streams, toggle publish, trigger scrape

**Background Services:**
- Scraper: Started in goroutine at startup via `scraper.Run(ctx)`
- Session cleanup: Goroutine with hourly ticker
- Proxy rate-limit cleanup: Goroutine with 10-minute ticker

## Error Handling

**Strategy:** Error strings returned in JSON responses with appropriate HTTP status codes. Panics caught and logged by recovery middleware.

**Patterns:**
- Validation errors: `400 Bad Request`
- Authentication failures: `401 Unauthorized`
- Permission denied: `403 Forbidden`
- Resource not found: `404 Not Found`
- Duplicate entries: `409 Conflict`
- Server errors: `500 Internal Server Error`
- Rate limit exceeded: `429 Too Many Requests`

Errors include descriptive messages: `{"error":"username must be 3-30 chars, alphanumeric or underscore"}`

## Cross-Cutting Concerns

**Logging:** stdlib log package
- Request logging: Method, path, remote address via `LoggingMiddleware`
- Scraper logging: Intervals, timing, link counts
- Proxy logging: Fetch errors
- All goes to stdout

**Validation:**
- Username: 3-30 chars, alphanumeric + underscore
- URLs: Must be HTTP(S), max 2048 chars, proxy-only supports HTTPS
- HTML escaping on stream titles to prevent injection

**Authentication:**
- WebAuthn for registration/login (passwordless)
- Session tokens as HttpOnly, Secure, SameSite=Strict cookies
- Configurable session TTL (default 720 hours)
- First registered user becomes admin unless ADMIN_USERNAME env var set

**CORS/Origin Check:**
- Origin header validated on mutation requests (POST, PUT, DELETE)
- Allowed origins configurable via WEBAUTHN_ORIGIN env var (comma-separated)
- CSRF protection via origin validation

---

*Architecture analysis: 2026-02-17*
