# Codebase Structure

**Analysis Date:** 2026-02-17

## Directory Layout

```
f1-stream/
├── main.go                 # Entry point, service initialization, signal handling
├── go.mod                  # Go module definition
├── go.sum                  # Dependency lock file
├── Dockerfile              # Container image definition
├── redeploy.sh            # Kubernetes redeployment script
├── index.html             # HTML template served at root
├── internal/              # Private Go packages
│   ├── auth/              # WebAuthn authentication and session management
│   ├── models/            # Domain data types
│   ├── server/            # HTTP handlers, routes, middleware
│   ├── store/             # File-based persistence layer
│   ├── scraper/           # Reddit content scraper
│   └── proxy/             # HTTP proxy with rate limiting
├── static/                # Frontend assets served to clients
│   ├── index.html         # Main SPA template
│   ├── css/               # Stylesheets
│   └── js/                # Client-side JavaScript modules
└── .planning/             # Planning/documentation directory
    └── codebase/          # Architecture analysis documents
```

## Directory Purposes

**Root Level:**
- Purpose: Service configuration and entry point
- Contains: Go module, main executable, Docker configuration, shell scripts
- Key files: `main.go` (service bootstrap), `go.mod` (dependencies)

**`internal/`:**
- Purpose: Private packages (not importable by external code)
- Contains: All business logic, separated by concern
- Key pattern: Each subdirectory is a distinct Go package with clear responsibility

**`internal/auth/`:**
- Purpose: User authentication, session management, context helpers
- Contains: WebAuthn ceremony handlers, session token management, user-in-context utilities
- Key files:
  - `auth.go`: Registration/login handlers, ceremony session storage, credential validation
  - `context.go`: Request context helpers for passing user data between middleware and handlers

**`internal/models/`:**
- Purpose: Domain model definitions
- Contains: User, Stream, ScrapedLink, Session type definitions
- Key files: `models.go` (all types, includes WebAuthn interface implementations)

**`internal/server/`:**
- Purpose: HTTP API and routing layer
- Contains: Handler functions, route registration, middleware implementations
- Key files:
  - `server.go`: Server struct, route registration, API handlers (streams, admin, public endpoints)
  - `middleware.go`: LoggingMiddleware, RecoveryMiddleware, AuthMiddleware, RequireAuth, RequireAdmin, OriginCheck

**`internal/store/`:**
- Purpose: Persistent storage abstraction over file system
- Contains: JSON file operations, per-entity storage methods, atomic write patterns
- Key files:
  - `store.go`: Store struct, directory initialization, JSON helper functions (readJSON, writeJSON)
  - `streams.go`: Stream CRUD operations, publish toggle, seeding
  - `users.go`: User lookup, credential updates, admin count
  - `sessions.go`: Session creation, validation, expiry cleanup
  - `scraped.go`: Scraped link persistence, active link filtering

**`internal/scraper/`:**
- Purpose: Background content aggregation
- Contains: Interval-based scraper, Reddit-specific scraper logic
- Key files:
  - `scraper.go`: Scraper service, interval-based run loop, manual trigger mechanism, deduplication logic
  - `reddit.go`: Reddit API polling, F1 keyword filtering, URL extraction (not included in sample reads but referenced)

**`internal/proxy/`:**
- Purpose: HTTP content fetching with security controls and rate limiting
- Contains: Rate limiter, private IP validation, response modification
- Key files: `proxy.go` (implements http.Handler, rate limiting, content fetching, base tag injection)

**`static/`:**
- Purpose: Frontend assets served to browser
- Contains: HTML template and client-side code
- Key files:
  - `index.html`: SPA HTML template (includes script tags loading js/)
  - `js/app.js`: Toast notifications, dialog system, tab switching, initialization
  - `js/auth.js`: Registration/login UI, WebAuthn client ceremony
  - `js/streams.js`: Stream display, filtering, admin operations
  - `js/utils.js`: Shared utilities (HTML escaping)
  - `css/`: Stylesheets for app UI

## Key File Locations

**Entry Points:**
- `main.go`: Service initialization, dependency injection, signal handling, goroutine startup

**Configuration:**
- Environment variables read in `main.go` (LISTEN_ADDR, DATA_DIR, SCRAPE_INTERVAL, etc.)
- WebAuthn config passed to `auth.New()`
- `.env` files not tracked (see .gitignore)

**Core Logic:**
- Request routing: `internal/server/server.go:registerRoutes()`
- Auth logic: `internal/auth/auth.go`
- Data storage: `internal/store/store.go` and per-entity files
- Scraping: `internal/scraper/scraper.go`
- Proxying: `internal/proxy/proxy.go`

**Testing:**
- No test files present in codebase (see TESTING.md concerns section)

## Naming Conventions

**Files:**
- Go source files: lowercase with underscores (e.g., `auth.go`, `middleware.go`)
- JavaScript files: lowercase with hyphens or underscores (e.g., `app.js`, `auth.js`)
- JSON data files: lowercase (e.g., `streams.json`, `users.json`, `sessions.json`)

**Directories:**
- Go packages: lowercase, single word preferred (e.g., `auth`, `store`, `models`)
- Frontend assets: plural nouns (e.g., `static`, `css`, `js`)

**Functions:**
- Go: CamelCase (exported), camelCase (unexported)
- JavaScript: camelCase throughout (e.g., `loadPublicStreams()`, `showToast()`)

**Types:**
- Go structs: CamelCase (e.g., `User`, `Stream`, `Store`, `Auth`)
- Methods: CamelCase (e.g., `BeginLogin()`, `AddStream()`)

**Variables:**
- Go: camelCase (e.g., `listenAddr`, `dataDir`, `adminUsername`)
- JavaScript: camelCase (e.g., `container`, `userID`, `sessionToken`)

## Where to Add New Code

**New Feature (e.g., new stream filter):**
- Primary code: Add handler in `internal/server/server.go`, register route in `registerRoutes()`
- Store operations: Add method to appropriate file in `internal/store/` (likely `streams.go`)
- Frontend: Add UI in `static/` and API call in `static/js/streams.js` or new module
- Models: Extend types in `internal/models/models.go` if new fields needed

**New Authentication Method:**
- Core implementation: New file in `internal/auth/` (e.g., `oauth.go`)
- Handlers: Add methods following WebAuthn pattern (BeginXxx, FinishXxx)
- Routes: Register in `registerRoutes()`
- Frontend: Add form/button in `static/js/auth.js`

**New Background Service (e.g., content validator):**
- Implementation: New file in `internal/` or new package `internal/validator/`
- Integration: Initialize in `main()` alongside `scraper.New()`
- Lifecycle: Use context pattern from scraper's `Run(ctx)` method
- Storage: Use existing `Store` instance

**Utilities/Helpers:**
- Shared by Go packages: Add to package where most useful, or create new `internal/util/` package
- Shared by frontend: Add to `static/js/utils.js` or create new module
- Shared helpers pattern: Functions not tied to single package, used across multiple

## Special Directories

**`internal/`:**
- Purpose: Enforce package privacy (cannot be imported by external code)
- Generated: No
- Committed: Yes

**`static/`:**
- Purpose: Served directly to clients via `http.FileServer`
- Generated: No (hand-written frontend)
- Committed: Yes

**`.planning/codebase/`:**
- Purpose: Architecture documentation for development guidance
- Generated: No (manually created by mapping process)
- Committed: Yes

**Data Directory (runtime):**
- Purpose: Persistent JSON files (streams.json, users.json, sessions.json, scraped.json)
- Location: Specified by DATA_DIR env var (default `/data`)
- Generated: Yes (created on first run)
- Committed: No (varies per deployment environment)

## Import Patterns

**Go Package Imports:**
- Standard library first: `import ("context" "fmt" "log")`
- Internal packages second: `import ("f1-stream/internal/auth" "f1-stream/internal/store")`
- External third-party last: `import ("github.com/go-webauthn/webauthn/webauthn")`

**Cross-Package Dependencies:**
- Server depends on: Auth, Store, Proxy, Scraper, Models
- Auth depends on: Store, Models
- Scraper depends on: Store, Models
- Proxy depends on: none (standalone service)
- Store depends on: Models
- Models depends on: external WebAuthn library only

---

*Structure analysis: 2026-02-17*
