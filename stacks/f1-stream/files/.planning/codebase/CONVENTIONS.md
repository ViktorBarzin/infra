# Coding Conventions

**Analysis Date:** 2026-02-17

## Naming Patterns

**Files:**
- Go packages: lowercase, single word when possible (e.g., `auth`, `store`, `proxy`)
- Go files: lowercase with descriptive names (e.g., `server.go`, `middleware.go`, `reddit.go`)
- JSON files: snake_case (e.g., `users.json`, `sessions.json`, `scraped_links.json`)
- JavaScript files: camelCase (e.g., `app.js`, `auth.js`, `streams.js`)

**Functions and Methods:**
- Go: PascalCase for exported functions (e.g., `New`, `BeginRegistration`, `ServeHTTP`)
- Go: camelCase for unexported functions (e.g., `randomID`, `isF1Post`, `normalizeURL`)
- JavaScript: camelCase for all functions (e.g., `showToast`, `switchTab`, `doRegister`)

**Variables and Fields:**
- Go: camelCase for local variables (e.g., `streams`, `userID`, `sessionTTL`)
- Go: PascalCase for exported struct fields (e.g., `ID`, `Username`, `IsAdmin`)
- Go: prefixed mutex pattern: `resourceMu` for mutex protecting resource (e.g., `streamsMu`, `usersMu`, `sessionsMu`)
- JavaScript: camelCase for all variables (e.g., `currentUser`, `beginResp`, `container`)

**Types and Constants:**
- Go: PascalCase for exported types (e.g., `Server`, `Auth`, `Store`, `User`)
- Go: camelCase for unexported types (e.g., `contextKey`, `bucket`, `redditListing`)
- Go: SCREAMING_SNAKE_CASE for constants (e.g., `maxBodySize`, `rateLimit`, `bucketCleanup`)

**Interfaces:**
- Go context keys use private types with exported constants (e.g., `type contextKey string; const userKey contextKey = "user"`)

## Code Style

**Formatting:**
- Language: Go (no automated formatter config detected, using standard gofmt conventions)
- Import organization: Standard library → local packages (separated by blank line)
- File layout: Package declaration → Imports → Constants/Variables → Types → Functions

**Linting:**
- No eslint or golangci-yml configuration found
- Go code follows idiomatic Go conventions: error checking, defer cleanup, interface composition

## Import Organization

**Go Order:**
1. Standard library imports (context, encoding/json, fmt, log, etc.)
2. Blank line
3. Local f1-stream packages (internal/auth, internal/models, etc.)
4. Blank line
5. External third-party packages (github.com/...)

**Example from `internal/auth/auth.go`:**
```go
import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"regexp"
	"sync"
	"time"

	"f1-stream/internal/models"
	"f1-stream/internal/store"

	"github.com/go-webauthn/webauthn/webauthn"
)
```

**JavaScript:**
- No explicit import organization (vanilla JavaScript, no modules)
- HTML file loads scripts in order: utils → app → auth/streams

## Error Handling

**Patterns:**
- Go: Explicit error return as second value (e.g., `err := operation(); if err != nil { return err }`)
- Go: Wrapping errors with context: `fmt.Errorf("operation failed: %w", err)`
- Go: String matching on error messages for classification (see `internal/server/server.go` line 196-205)
- Go: Logging errors with `log.Printf()` for non-critical failures, `log.Fatalf()` for startup errors
- Go: HTTP errors returned via `http.Error(w, message, statusCode)` for API endpoints
- JavaScript: Try-catch blocks for async operations, error fields in UI (e.g., `errEl.textContent = err.error || 'Operation failed'`)

**HTTP Error Responses:**
- Standard JSON format: `{"error":"description"}`
- Success responses vary by endpoint (JSON arrays, `{"ok":true}`, encoded objects via `json.NewEncoder`)

## Logging

**Framework:** `log` package (standard library)

**Patterns:**
- Informational: `log.Printf("message with %v context", value)`
- Errors: `log.Printf("operation failed: %v", err)`
- Startup: `log.Fatalf("critical: %v", err)` for initialization failures
- Component prefixes: `log.Printf("scraper: action description")`

**Example from `internal/scraper/scraper.go`:**
```go
log.Printf("scraper: starting scrape")
log.Printf("scraper: error after %v: %v", time.Since(start).Round(time.Millisecond), err)
log.Printf("scraper: done in %v, added %d new links (total: %d)", time.Since(start).Round(time.Millisecond), added, len(existing))
```

## Comments

**When to Comment:**
- Explain WHY, not WHAT (code shows what, comments explain reasoning)
- Used for non-obvious logic or security concerns
- Example from `internal/proxy/proxy.go` line 123: `// Explicitly do NOT copy X-Frame-Options or CSP`
- Example from `internal/auth/auth.go` line 120: `// Store user temporarily - will be committed on finish`

**Patterns:**
- Short inline comments before complex sections
- Package-level comments before exported types explaining purpose
- Security/business logic gets explained

## Function Design

**Size:** Functions keep complexity low, typically 20-50 lines; larger operations split across helpers

**Parameters:**
- Receiver methods use pointer receivers: `func (s *Store) GetSession(token string) ...`
- Constructor pattern returns initialized type and error: `func New(...) (*Type, error)`
- HTTP handlers follow signature: `func(w http.ResponseWriter, r *http.Request)`

**Return Values:**
- Errors always returned as last value: `(result, error)`
- Multiple return values when needed: `(*Type, error)` or `([]Type, error)`
- HTTP handlers write directly to ResponseWriter, return via `http.Error()` or direct writes
- Query methods return nil for "not found" rather than error (see `internal/store/users.go` line 33)

## Module Design

**Exports:**
- Exported names start with capital letter (e.g., `New`, `User`, `Server`)
- Unexported helpers start with lowercase
- Types exported when they're part of public API
- Helper functions (e.g., `isF1Post`, `normalizeURL`) kept unexported

**Barrel Files:** Not used; single concerns per file

**Package Organization:**
- `internal/auth/`: Authentication and WebAuthn implementation
- `internal/store/`: Data persistence (users.go, streams.go, sessions.go, scraped.go, store.go)
- `internal/server/`: HTTP routing and middleware
- `internal/scraper/`: Reddit scraping logic
- `internal/proxy/`: HTTP proxy with rate limiting
- `internal/models/`: Type definitions only

**Struct Composition:**
- `Server` struct holds dependencies injected at construction (line 15-21 in `internal/server/server.go`)
- Methods extend functionality through receiver pattern
- No inheritance, composition via embedded types used sparingly

---

*Convention analysis: 2026-02-17*
