# Testing Patterns

**Analysis Date:** 2026-02-17

## Test Framework

**Status:** No testing infrastructure present

**Runner:** Not detected

**Assertion Library:** Not applicable

**Run Commands:** Not applicable

## Test File Organization

**Current State:** Zero test files found

After scanning the codebase:
- No `*_test.go` files in `internal/` packages
- No `*.test.js` or `*.spec.js` files in static assets
- No test configuration files (jest.config.js, vitest.config.ts, etc.)
- No test runners in go.mod dependencies

## Test Coverage

**Requirements:** Not enforced; no test infrastructure

**Current Coverage:** 0% - no tests exist

## Test Types Present in Codebase

### Unit Test Candidates (Not Currently Tested)

**`internal/models/models.go`:**
- User and Stream model struct definitions
- WebAuthn interface implementations (lines 18-21)

**`internal/auth/auth.go`:**
- Username validation via regex `usernameRe` (line 19)
- Registration/login ceremony steps
- Session creation and token generation
- Admin user detection logic (lines 83-91)

**`internal/store/*.go` (all files):**
- JSON read/write operations with file locking
- User lookup and stream operations
- Session creation, validation, and cleanup
- Scraped link filtering and deduplication

**`internal/scraper/reddit.go`:**
- F1 post detection: `isF1Post()` function (line 272-285)
- URL normalization: `normalizeURL()` function (line 262-270)
- URL extraction: `extractURLs()` function (line 210-243)
- Comment walking: `walkComments()` function (line 245-260)
- Keyword matching logic (lines 29-45)
- Retry logic with backoff (lines 183-208)

**`internal/proxy/proxy.go`:**
- Rate limiting with token bucket algorithm (lines 145-168)
- Private host detection: `isPrivateHost()` function (line 128-143)
- Client IP extraction: `clientAddr()` function (line 184-191)
- Bucket cleanup mechanism (lines 170-182)

**`internal/server/middleware.go`:**
- Auth middleware context injection
- Authorization checks (RequireAuth, RequireAdmin)
- Origin validation for CSRF protection
- Panic recovery middleware

### Integration Test Candidates (Not Currently Tested)

**Authentication Flow:**
- Begin registration → finish registration → session creation
- Begin login → finish login → session creation
- Session validation and expiration
- WebAuthn ceremony with mock credentials

**Stream Management:**
- Add stream → save to JSON → retrieve
- Delete stream with authorization checks
- Toggle publish status
- Filter streams by visibility/ownership

**Scraping Pipeline:**
- Fetch Reddit listing
- Extract F1 posts
- Walk comments recursively
- Deduplicate URLs
- Merge with existing links

### E2E Test Candidates (Not Currently Tested)

**HTTP Endpoints:**
- Full registration flow (POST /api/auth/register/begin, /api/auth/register/finish)
- Full login flow (POST /api/auth/login/begin, /api/auth/login/finish)
- Stream CRUD operations
- Public stream viewing
- Scrape triggering and result retrieval

## Critical Untested Paths

**High Risk - Security:**
- Authentication middleware context injection (`internal/server/middleware.go` lines 33-43)
- Admin authorization checks (line 62)
- CSRF origin validation (line 78-88)
- Private address filtering in proxy (line 77-80 in `internal/proxy/proxy.go`)
- Rate limiting enforcement (line 62-65 in `internal/proxy/proxy.go`)

**High Risk - Data Integrity:**
- Concurrent access to store files via mutex protection (no verification that race conditions are prevented)
- JSON read/write atomicity with temp files (lines 41-52 in `internal/store/store.go`)
- Session expiration cleanup (lines 83-98 in `internal/store/sessions.go`)
- Stream deduplication during scraping (lines 65-85 in `internal/scraper/scraper.go`)

**Medium Risk - Business Logic:**
- F1 post detection with negative keywords (lines 272-285 in `internal/scraper/reddit.go`)
- URL normalization for deduplication (line 262-270)
- Retry logic with rate limit backoff (line 183-208)

## What Needs Testing

### Unit Test Suggestions

```go
// Example: Test username validation
func TestUsernameValidation(t *testing.T) {
    tests := []struct {
        username string
        valid    bool
    }{
        {"valid123", true},
        {"valid_name", true},
        {"ab", false},  // too short
        {"invalid-char", false},  // invalid character
        {"", false},  // empty
    }
    // usernameRe.MatchString(username) for each test case
}

// Example: Test F1 post detection
func TestIsF1Post(t *testing.T) {
    tests := []struct {
        title    string
        expected bool
    }{
        {"F1 GP Race - Monaco", true},
        {"Formula 1 Practice", true},
        {"Help with F1 key binding", false},  // negative keyword
        {"Random post about cars", false},
    }
    // isF1Post(title) for each test case
}

// Example: Test URL normalization
func TestNormalizeURL(t *testing.T) {
    // Check that different URL formats normalize to same string
    // Check case-insensitivity and trailing slash handling
}

// Example: Test rate limiting
func TestRateLimiting(t *testing.T) {
    p := New(10 * time.Second)
    ip := "192.168.1.1"

    // First burst allowed
    for i := 0; i < 5; i++ {
        if !p.allowRequest(ip) {
            t.Fail()
        }
    }

    // Burst exhausted
    if p.allowRequest(ip) {
        t.Fail()
    }

    // Wait and verify replenishment
    time.Sleep(10 * time.Second)
    if !p.allowRequest(ip) {
        t.Fail()
    }
}
```

### Integration Test Suggestions

```go
// Example: Test store operations with concurrency
func TestConcurrentStreamOperations(t *testing.T) {
    st, _ := store.New(t.TempDir())

    // Concurrent adds from multiple goroutines
    // Verify no data corruption
    // Verify final count is correct
}

// Example: Test scraper deduplication
func TestScraperDeduplication(t *testing.T) {
    // Create scraper with test store
    // Mock Reddit response with duplicate URLs
    // Verify only unique URLs are stored
    // Verify normalization works (http vs https, trailing slashes)
}

// Example: Test auth middleware
func TestAuthMiddleware(t *testing.T) {
    st, _ := store.New(t.TempDir())
    auth, _ := auth.New(st, ...)

    // Create test token
    // Make request with session cookie
    // Verify user injected into context
}
```

## Recommended Testing Strategy

1. **Phase 1 - Unit Tests (Highest Priority):**
   - Validation functions (username regex, F1 keywords)
   - String utilities (URL normalization, truncate)
   - Rate limiting algorithm
   - Private host detection

2. **Phase 2 - Integration Tests:**
   - Store operations with concurrency (verify mutex protection)
   - Scraper pipeline (Reddit fetch → parse → deduplicate → save)
   - Auth ceremony flow with mock WebAuthn
   - Stream CRUD with permission checks

3. **Phase 3 - E2E Tests:**
   - Full HTTP request flows
   - Middleware chain validation
   - Session management across endpoints

## Testing Patterns to Establish

**Once framework chosen (Go: testing or testify):**

- Use `t.TempDir()` for store tests to avoid file conflicts
- Mock HTTP responses for scraper tests
- Use `net/http/httptest` for handler testing
- Mock WebAuthn responses for auth tests
- Table-driven tests for validation logic
- Parallel test execution with `-race` flag for concurrency detection

**Coverage gaps to close:**
- All error paths in store operations
- Session expiration edge cases
- Concurrent access scenarios
- HTTP header validation
- CORS/origin validation

---

*Testing analysis: 2026-02-17*
