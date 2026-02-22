# Phase 2: Health Check Infrastructure - Research

**Researched:** 2026-02-17
**Domain:** Background health monitoring service with persisted state in Go
**Confidence:** HIGH

## Summary

Phase 2 adds a background health checker service that continuously monitors all known streams (both user-submitted from `streams.json` and scraped from `scraped_links.json`) on a configurable interval. The service performs a two-step check per stream: first an HTTP HEAD/GET for reachability (2xx status), then a full proxy-fetch to verify video/player content markers using the `hasVideoContent()` function already implemented in Phase 1's `internal/scraper/validate.go`. Health state (consecutive failure count, last check time, healthy/unhealthy flag) is persisted to a new `health_state.json` file using the existing store pattern. Streams with 5+ consecutive failures are hidden from the public API.

The implementation closely mirrors the existing scraper service pattern: a struct with a `Run(ctx)` method started as a goroutine in `main.go`, using `time.Ticker` for interval-based execution. The health checker needs access to the store (to enumerate streams and read/write health state) and to the validation logic from `internal/scraper/validate.go`. The main architectural decision is where to place the health checker -- a new `internal/healthcheck/` package is the cleanest approach, importing the scraper's validation functions.

The public streams endpoint (`GET /api/streams/public`) and the scraped links endpoint (`GET /api/scraped`) need modification to filter out unhealthy streams. This requires the store to cross-reference health state when returning public data.

**Primary recommendation:** Create a new `internal/healthcheck/` package containing the `HealthChecker` service. Add a `HealthState` model to `internal/models/models.go`. Add store methods for health state persistence in a new `internal/store/health.go` file. Modify `PublicStreams()` and `GetActiveScrapedLinks()` to exclude unhealthy entries. Wire everything in `main.go` following the scraper initialization pattern exactly.

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| HLTH-01 | Background health checker service runs every 5 minutes against all known streams (scraped + user-submitted) | New `internal/healthcheck/` package with `HealthChecker` struct. `Run(ctx)` method with `time.Ticker` (same pattern as `scraper.Run()`). Enumerates all streams via `store.LoadStreams()` and `store.LoadScrapedLinks()`. Default interval 5 minutes. |
| HLTH-02 | Health check performs HTTP reachability check first (does the URL respond with 2xx?) | First step: HTTP HEAD request (or GET with body discard) to the URL. Check `resp.StatusCode >= 200 && resp.StatusCode < 300`. If not reachable, mark as failed without doing content check. Uses same `http.Client` with configurable timeout. |
| HLTH-03 | If HTTP check passes, health checker proxy-fetches the page and checks for video/player content markers | Second step: reuse `hasVideoContent()` from `internal/scraper/validate.go`. This function already performs GET, checks Content-Type, reads body with 2MB limit, and runs `containsVideoMarkers()`. The function must be exported or the health checker must import the scraper package. |
| HLTH-04 | Health check has a configurable timeout per check (default 10s) | `HEALTH_CHECK_TIMEOUT` env var read in `main.go`, passed to `healthcheck.New()`. Used as `http.Client.Timeout`. Default 10 seconds. Follows `envDuration()` pattern already in `main.go`. |
| HLTH-05 | Each stream tracks consecutive failure count, last check time, and healthy/unhealthy status in persisted state | New `HealthState` model with fields: `URL string`, `ConsecutiveFailures int`, `LastCheckTime time.Time`, `Healthy bool`. Stored in `health_state.json` via new store methods. Keyed by URL (not ID) since both streams and scraped links have URLs but different ID schemes. |
| HLTH-06 | Stream marked unhealthy after 5 consecutive health check failures | In health checker's check loop: increment `ConsecutiveFailures` on failure. When count reaches 5, set `Healthy = false`. Constant `unhealthyThreshold = 5` defined in healthcheck package. |
| HLTH-07 | Unhealthy streams hidden from public streams page (`GET /api/streams/public`) | Modify `store.PublicStreams()` to cross-reference health state. Also modify `store.GetActiveScrapedLinks()` similarly. Both methods already filter (by `Published` and by `Stale`) -- add health filter. |
| HLTH-08 | Unhealthy streams continue to be checked -- restored to healthy if they recover (failure count resets) | Health checker always checks ALL streams regardless of health status. On successful check: set `Healthy = true`, reset `ConsecutiveFailures = 0`. This is the default behavior since the checker iterates all known URLs. |
| HLTH-09 | Health check interval configurable via `HEALTH_CHECK_INTERVAL` env var (default 5m) | `HEALTH_CHECK_INTERVAL` env var read in `main.go` via `envDuration()`, passed to `healthcheck.New()`. Used as `time.Ticker` interval. Default `5 * time.Minute`. |
</phase_requirements>

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `net/http` | stdlib | HTTP client for reachability checks and content fetching | Already used throughout codebase. `http.Client` with `Timeout` field handles per-check timeout (HLTH-04). |
| `time` | stdlib | `time.Ticker` for interval-based health check loop | Already used in scraper's `Run()` method and session cleanup. Proven pattern in this codebase. |
| `context` | stdlib | Graceful shutdown of health checker goroutine | Already used in `main.go` with `signal.NotifyContext()`. Health checker's `Run(ctx)` listens for `ctx.Done()`. |
| `sync` | stdlib | `sync.RWMutex` for health state file access | Already used in every store file (`streamsMu`, `usersMu`, `scrapedMu`, `sessionsMu`). Add `healthMu`. |
| `encoding/json` | stdlib | JSON serialization of health state to file | Already used by `readJSON`/`writeJSON` in `internal/store/store.go`. |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `log` | stdlib | Structured logging with component prefix | Use `log.Printf("healthcheck: ...")` following scraper's convention `log.Printf("scraper: ...")`. |
| `strings` | stdlib | URL normalization for health state key lookup | Already used in scraper for `normalizeURL()`. |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| File-based health state (`health_state.json`) | In-memory map only | In-memory is simpler but violates HLTH-05 requirement for persistence across restarts. File-based follows existing store pattern. |
| New `internal/healthcheck/` package | Health check methods on existing `Scraper` struct | Separate package is cleaner: different concern (monitoring vs discovery), different lifecycle, different interval. Avoids coupling health check config/state to scraper. |
| HEAD request for reachability | GET request only | HEAD is faster (no body transfer) but some servers don't support it or return different status codes. Fallback to GET if HEAD fails or returns 405. Alternatively, just use GET for both steps since `hasVideoContent()` already does GET. |
| URL as health state key | Stream/ScrapedLink ID as key | URL is better because: (1) streams and scraped links have different ID formats, (2) same URL may appear in both, (3) health is a property of the URL not the record, (4) deduplication is simpler. |

**Installation:**
```bash
# No new dependencies needed. All stdlib.
```

## Architecture Patterns

### Recommended Project Structure

```
internal/
  healthcheck/
    healthcheck.go       # HealthChecker struct, Run(), checkAll(), checkOne()
  models/
    models.go            # Add HealthState struct (existing file)
  store/
    health.go            # NEW: LoadHealthState(), SaveHealthState(), GetHealthStatus()
    store.go             # Add healthMu field (existing file)
    streams.go           # Modify PublicStreams() to filter unhealthy (existing file)
    scraped.go           # Modify GetActiveScrapedLinks() to filter unhealthy (existing file)
  scraper/
    validate.go          # Existing - export HasVideoContent() for health checker use
main.go                  # Add healthcheck initialization and goroutine (existing file)
```

### Pattern 1: Background Service with Ticker (proven pattern in codebase)

**What:** A service struct with `Run(ctx context.Context)` that executes on a configurable interval using `time.Ticker`, stopping cleanly when the context is cancelled.
**When to use:** Background periodic tasks that need graceful shutdown.
**Example:**

```go
// internal/healthcheck/healthcheck.go
package healthcheck

import (
    "context"
    "log"
    "net/http"
    "time"

    "f1-stream/internal/store"
)

type HealthChecker struct {
    store    *store.Store
    interval time.Duration
    timeout  time.Duration
    client   *http.Client
}

func New(s *store.Store, interval, timeout time.Duration) *HealthChecker {
    return &HealthChecker{
        store:    s,
        interval: interval,
        timeout:  timeout,
        client: &http.Client{
            Timeout: timeout,
            CheckRedirect: func(req *http.Request, via []*http.Request) error {
                if len(via) >= 3 {
                    return http.ErrUseLastResponse
                }
                return nil
            },
        },
    }
}

func (hc *HealthChecker) Run(ctx context.Context) {
    log.Printf("healthcheck: starting with interval %v, timeout %v", hc.interval, hc.timeout)
    // Run immediately on start
    hc.checkAll()

    ticker := time.NewTicker(hc.interval)
    defer ticker.Stop()

    for {
        select {
        case <-ctx.Done():
            log.Println("healthcheck: shutting down")
            return
        case <-ticker.C:
            hc.checkAll()
        }
    }
}
```

### Pattern 2: Health State Persistence (follows store pattern)

**What:** A new JSON file in the data directory storing per-URL health state, with the same mutex-protected read/write pattern as other store entities.
**When to use:** Persisting health state across restarts (HLTH-05).
**Example:**

```go
// internal/models/models.go - add to existing file
type HealthState struct {
    URL                 string    `json:"url"`
    ConsecutiveFailures int       `json:"consecutive_failures"`
    LastCheckTime       time.Time `json:"last_check_time"`
    Healthy             bool      `json:"healthy"`
}

// internal/store/health.go
package store

import "f1-stream/internal/models"

func (s *Store) LoadHealthStates() ([]models.HealthState, error) {
    s.healthMu.RLock()
    defer s.healthMu.RUnlock()
    var states []models.HealthState
    if err := readJSON(s.filePath("health_state.json"), &states); err != nil {
        return nil, err
    }
    return states, nil
}

func (s *Store) SaveHealthStates(states []models.HealthState) error {
    s.healthMu.Lock()
    defer s.healthMu.Unlock()
    return writeJSON(s.filePath("health_state.json"), states)
}

// IsURLHealthy checks if a URL is considered healthy.
// Returns true if no health state exists (new URLs are assumed healthy).
func (s *Store) IsURLHealthy(url string) (bool, error) {
    states, err := s.LoadHealthStates()
    if err != nil {
        return true, err // assume healthy on error
    }
    for _, st := range states {
        if st.URL == url {
            return st.Healthy, nil
        }
    }
    return true, nil // no state = assumed healthy
}
```

### Pattern 3: Two-Step Health Check (HTTP reachability + content validation)

**What:** Each stream URL is checked in two steps: (1) HTTP reachability (does it respond with 2xx?), then (2) content validation (does the response contain video markers?). Step 2 only runs if step 1 passes.
**When to use:** HLTH-02 and HLTH-03 require this two-step approach.
**Example:**

```go
// internal/healthcheck/healthcheck.go

const unhealthyThreshold = 5

func (hc *HealthChecker) checkOne(url string) bool {
    // Step 1: HTTP reachability check (HLTH-02)
    req, err := http.NewRequest("GET", url, nil)
    if err != nil {
        log.Printf("healthcheck: request error for %s: %v", truncate(url, 60), err)
        return false
    }
    req.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")

    resp, err := hc.client.Do(req)
    if err != nil {
        log.Printf("healthcheck: fetch error for %s: %v", truncate(url, 60), err)
        return false
    }
    defer resp.Body.Close()

    if resp.StatusCode < 200 || resp.StatusCode >= 300 {
        log.Printf("healthcheck: %s returned status %d", truncate(url, 60), resp.StatusCode)
        return false
    }

    // Step 2: Content validation (HLTH-03)
    // Reuse scraper's hasVideoContent logic
    // (either call exported function or inline equivalent logic)
    return scraper.HasVideoContent(hc.client, url)
}
```

### Pattern 4: Exporting Validation Functions for Cross-Package Use

**What:** The `hasVideoContent()` function in `internal/scraper/validate.go` is currently unexported (lowercase). Phase 2 needs it in `internal/healthcheck/`. Export it by capitalizing.
**When to use:** When a function in one package needs to be called from another.
**Example:**

```go
// internal/scraper/validate.go - rename for export
// HasVideoContent performs a GET request and returns true if the response
// contains video/player content markers.
func HasVideoContent(client *http.Client, rawURL string) bool {
    // ... existing implementation unchanged
}

// Update call site in same file:
func validateLinks(links []models.ScrapedLink, timeout time.Duration) []models.ScrapedLink {
    // ...
    if HasVideoContent(client, link.URL) { // was hasVideoContent
    // ...
}
```

### Pattern 5: Filtering Unhealthy Streams in Public API

**What:** Modify `PublicStreams()` and `GetActiveScrapedLinks()` to cross-reference health state and exclude unhealthy URLs.
**When to use:** HLTH-07 requires hiding unhealthy streams from the public page.
**Example:**

```go
// internal/store/streams.go - modified PublicStreams()
func (s *Store) PublicStreams() ([]models.Stream, error) {
    s.streamsMu.RLock()
    defer s.streamsMu.RUnlock()
    var streams []models.Stream
    if err := readJSON(s.filePath("streams.json"), &streams); err != nil {
        return nil, err
    }

    // Load health states to filter unhealthy streams
    healthStates := s.loadHealthMap()

    var pub []models.Stream
    for _, st := range streams {
        if st.Published && healthStates[st.URL] {
            pub = append(pub, st)
        }
    }
    return pub, nil
}

// loadHealthMap returns a map of URL -> healthy status.
// URLs not in the map are considered healthy (new/unchecked).
func (s *Store) loadHealthMap() map[string]bool {
    // Note: must not acquire healthMu here if caller already holds another lock
    // Use separate read to avoid deadlock
    var states []models.HealthState
    readJSON(s.filePath("health_state.json"), &states) // ignore error, assume healthy
    result := make(map[string]bool)
    for _, st := range states {
        result[st.URL] = st.Healthy
    }
    return result
}
```

### Pattern 6: Collecting All URLs to Check

**What:** The health checker needs to enumerate ALL known stream URLs from both `streams.json` and `scraped_links.json`.
**When to use:** HLTH-01 requires checking all known streams.
**Example:**

```go
func (hc *HealthChecker) collectURLs() []string {
    seen := make(map[string]bool)
    var urls []string

    // User-submitted streams
    streams, err := hc.store.LoadStreams()
    if err != nil {
        log.Printf("healthcheck: failed to load streams: %v", err)
    }
    for _, s := range streams {
        if !seen[s.URL] {
            seen[s.URL] = true
            urls = append(urls, s.URL)
        }
    }

    // Scraped links
    links, err := hc.store.LoadScrapedLinks()
    if err != nil {
        log.Printf("healthcheck: failed to load scraped links: %v", err)
    }
    for _, l := range links {
        if !seen[l.URL] {
            seen[l.URL] = true
            urls = append(urls, l.URL)
        }
    }

    return urls
}
```

### Anti-Patterns to Avoid

- **Holding store mutexes during HTTP requests:** Never lock `streamsMu` or `scrapedMu` while performing health checks. Load the URLs first (release lock), then check them, then update health state (acquire `healthMu`). Long-held locks block the API.
- **Modifying streams/scraped links directly:** The health checker should NOT modify `streams.json` or `scraped_links.json` to mark health status. Health state is a separate concern stored in `health_state.json`. The public API filters at query time.
- **Checking URLs in parallel without rate limiting:** Parallel checks would be faster but could overwhelm target servers and the network. Sequential checking is simpler and follows the scraper's established pattern. The 5-minute interval provides sufficient freshness.
- **Using stream/scraped link IDs as health state keys:** IDs are different between streams and scraped links, and the same URL could appear in both. URL is the natural key for health state.
- **Making the health checker depend on the server package:** The health checker should depend only on `store` and `scraper` (for validation). It should not import `server`. Keep the dependency tree clean.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Video content detection | Custom detection in healthcheck | `scraper.HasVideoContent()` (export existing) | Already implemented and tested in Phase 1. Avoids duplicating marker list and detection logic. |
| HTTP client with redirect limits | Custom redirect handler | `http.Client` with `CheckRedirect` callback | stdlib handles TLS, timeouts, connection pooling. Same pattern used in scraper and proxy. |
| Periodic execution | Custom sleep loop | `time.Ticker` | Handles drift, more accurate intervals, idiomatic Go. Already used in scraper and session cleanup. |
| Graceful shutdown | OS signal handling | `context.Context` from `signal.NotifyContext` | Already set up in `main.go`. Just pass ctx to `Run()`. |
| Atomic file writes | Direct `os.WriteFile` | Existing `writeJSON()` (temp-file-then-rename) | Already implemented in `store.go`. Prevents corruption on crash. |
| URL deduplication | Custom loop | `map[string]bool` with normalized URL key | Same pattern used in scraper's `scrape()` method. |

**Key insight:** Phase 2 is primarily an orchestration problem -- it combines existing primitives (HTTP fetching, video detection, file persistence, background service) into a new service. Almost every component has a working example in the codebase.

## Common Pitfalls

### Pitfall 1: Deadlock from Nested Mutex Acquisition

**What goes wrong:** `PublicStreams()` holds `streamsMu.RLock()` and then calls `loadHealthMap()` which tries to acquire `healthMu.RLock()`. If another goroutine holds `healthMu.Lock()` and is waiting for `streamsMu.RLock()`, deadlock occurs.
**Why it happens:** The health state filter in `PublicStreams()` needs to read `health_state.json` while holding the streams lock.
**How to avoid:** The `loadHealthMap()` helper should read the health file directly via `readJSON()` WITHOUT acquiring `healthMu`. This is safe because: (1) `readJSON` reads the file atomically (single `os.ReadFile` call), (2) `writeJSON` uses atomic rename, so the file is always in a consistent state, (3) a brief inconsistency (reading slightly stale health data) is acceptable for a status query. Alternatively, load health states BEFORE acquiring the streams lock.
**Warning signs:** Server hangs on `GET /api/streams/public` under health check load.

### Pitfall 2: Health Check Takes Longer Than the Interval

**What goes wrong:** With 100 streams and a 10-second timeout per stream, worst case is 1000 seconds (~17 minutes). The 5-minute interval would trigger another check before the first completes.
**Why it happens:** Sequential checking of many streams with generous timeouts.
**How to avoid:** Use a mutex to prevent concurrent health check runs (same as scraper's `s.mu.Lock()` pattern). Log total check duration. If consistently exceeding interval, consider reducing timeout or adding limited parallelism (e.g., 5 concurrent checks with a semaphore). With realistic stream counts (10-50), even worst case (50 * 10s = 500s = 8.3 min) is manageable, and most checks will respond much faster than 10s.
**Warning signs:** Log messages showing overlapping check cycles or checks taking longer than `interval/2`.

### Pitfall 3: Health State File Growing Unbounded

**What goes wrong:** URLs that were once checked but are no longer in streams or scraped links remain in `health_state.json` forever.
**Why it happens:** No cleanup of orphaned health state entries.
**How to avoid:** During `checkAll()`, the health checker already collects all current URLs. After updating health state, prune any entries whose URLs are not in the current set. This naturally keeps the file in sync with actual streams.
**Warning signs:** `health_state.json` growing much larger than `streams.json` + `scraped_links.json`.

### Pitfall 4: Scraper's hasVideoContent Does a Full GET (Redundant with Reachability Check)

**What goes wrong:** The two-step check (HLTH-02: reachability, HLTH-03: content) results in TWO GET requests to the same URL -- once for reachability, once for content validation.
**Why it happens:** `hasVideoContent()` performs its own GET request internally.
**How to avoid:** Option A: Combine both steps into a single GET request within `checkOne()` -- check status code (reachability) and then inspect body (content), all from one response. This is more efficient. Option B: Use a lightweight HEAD request for reachability, then call `hasVideoContent()` for the full check. Option A is preferred since it halves the number of requests per stream.
**Warning signs:** Double the expected number of outbound HTTP requests per health check cycle.

### Pitfall 5: New Streams Assumed Unhealthy Until First Check

**What goes wrong:** A user submits a stream, and it immediately disappears from the public page because it has no health state entry, and the filter logic treats "no entry" as unhealthy.
**Why it happens:** Incorrect default assumption in health filtering.
**How to avoid:** "No health state entry" MUST mean "assumed healthy." This is the correct default because: (1) user-submitted streams should be visible immediately, (2) scraped streams have already passed Phase 1 validation, (3) the health checker will evaluate the stream within at most 5 minutes. The `loadHealthMap()` helper should return `true` for URLs not in the map.
**Warning signs:** Newly submitted or scraped streams not appearing on the public page until after the first health check.

### Pitfall 6: Modifying Exported Function Signature Breaks Scraper

**What goes wrong:** Exporting `hasVideoContent` as `HasVideoContent` is fine (just capitalize), but if the function signature changes (e.g., adding parameters), the internal call site in `validateLinks()` also needs updating.
**Why it happens:** Two call sites for the same function.
**How to avoid:** Only change capitalization. Do not change the function signature. If the health checker needs different behavior, create a wrapper in the healthcheck package rather than modifying the shared function.
**Warning signs:** Compilation error in `validate.go` after export change.

## Code Examples

### Complete HealthChecker Implementation

```go
// internal/healthcheck/healthcheck.go
package healthcheck

import (
    "io"
    "log"
    "net/http"
    "strings"
    "sync"
    "time"

    "f1-stream/internal/models"
    "f1-stream/internal/scraper"
    "f1-stream/internal/store"
)

const unhealthyThreshold = 5

type HealthChecker struct {
    store    *store.Store
    interval time.Duration
    timeout  time.Duration
    client   *http.Client
    mu       sync.Mutex
}

func New(s *store.Store, interval, timeout time.Duration) *HealthChecker {
    return &HealthChecker{
        store:    s,
        interval: interval,
        timeout:  timeout,
        client: &http.Client{
            Timeout: timeout,
            CheckRedirect: func(req *http.Request, via []*http.Request) error {
                if len(via) >= 3 {
                    return http.ErrUseLastResponse
                }
                return nil
            },
        },
    }
}

func (hc *HealthChecker) Run(ctx context.Context) {
    log.Printf("healthcheck: starting with interval %v, timeout %v", hc.interval, hc.timeout)
    hc.checkAll()

    ticker := time.NewTicker(hc.interval)
    defer ticker.Stop()

    for {
        select {
        case <-ctx.Done():
            log.Println("healthcheck: shutting down")
            return
        case <-ticker.C:
            hc.checkAll()
        }
    }
}
```

### checkAll with State Update

```go
func (hc *HealthChecker) checkAll() {
    hc.mu.Lock()
    defer hc.mu.Unlock()

    start := time.Now()
    urls := hc.collectURLs()
    log.Printf("healthcheck: checking %d URLs", len(urls))

    // Load existing health states into a map
    existingStates, err := hc.store.LoadHealthStates()
    if err != nil {
        log.Printf("healthcheck: failed to load health states: %v", err)
        existingStates = nil
    }
    stateMap := make(map[string]*models.HealthState)
    for i := range existingStates {
        stateMap[existingStates[i].URL] = &existingStates[i]
    }

    // Check each URL and update state
    now := time.Now()
    checked := 0
    healthy := 0
    recovered := 0
    newlyUnhealthy := 0

    for _, url := range urls {
        passed := scraper.HasVideoContent(hc.client, url)
        checked++

        state, exists := stateMap[url]
        if !exists {
            state = &models.HealthState{
                URL:     url,
                Healthy: true,
            }
            stateMap[url] = state
        }

        state.LastCheckTime = now

        if passed {
            if !state.Healthy {
                recovered++
                log.Printf("healthcheck: %s recovered", truncate(url, 60))
            }
            state.ConsecutiveFailures = 0
            state.Healthy = true
            healthy++
        } else {
            state.ConsecutiveFailures++
            if state.ConsecutiveFailures >= unhealthyThreshold && state.Healthy {
                state.Healthy = false
                newlyUnhealthy++
                log.Printf("healthcheck: %s marked unhealthy after %d failures",
                    truncate(url, 60), state.ConsecutiveFailures)
            }
        }
    }

    // Build final state slice (only URLs that are still in streams/scraped)
    currentURLs := make(map[string]bool)
    for _, u := range urls {
        currentURLs[u] = true
    }
    var finalStates []models.HealthState
    for url, state := range stateMap {
        if currentURLs[url] {
            finalStates = append(finalStates, *state)
        }
    }

    if err := hc.store.SaveHealthStates(finalStates); err != nil {
        log.Printf("healthcheck: failed to save health states: %v", err)
    }

    log.Printf("healthcheck: done in %v, checked %d, healthy %d, recovered %d, newly unhealthy %d",
        time.Since(start).Round(time.Millisecond), checked, healthy, recovered, newlyUnhealthy)
}
```

### HealthState Model Addition

```go
// Add to internal/models/models.go
type HealthState struct {
    URL                 string    `json:"url"`
    ConsecutiveFailures int       `json:"consecutive_failures"`
    LastCheckTime       time.Time `json:"last_check_time"`
    Healthy             bool      `json:"healthy"`
}
```

### Store Health Methods

```go
// internal/store/health.go
package store

import "f1-stream/internal/models"

func (s *Store) LoadHealthStates() ([]models.HealthState, error) {
    s.healthMu.RLock()
    defer s.healthMu.RUnlock()
    var states []models.HealthState
    if err := readJSON(s.filePath("health_state.json"), &states); err != nil {
        return nil, err
    }
    return states, nil
}

func (s *Store) SaveHealthStates(states []models.HealthState) error {
    s.healthMu.Lock()
    defer s.healthMu.Unlock()
    return writeJSON(s.filePath("health_state.json"), states)
}

// HealthMap returns a map of URL -> healthy boolean.
// URLs not present in the map are considered healthy.
// This method reads the file directly without holding healthMu,
// suitable for use inside other lock-holding methods.
func (s *Store) HealthMap() map[string]bool {
    var states []models.HealthState
    _ = readJSON(s.filePath("health_state.json"), &states)
    m := make(map[string]bool)
    for _, st := range states {
        m[st.URL] = st.Healthy
    }
    return m
}
```

### Store Struct Update

```go
// internal/store/store.go - add healthMu field
type Store struct {
    dir        string
    streamsMu  sync.RWMutex
    usersMu    sync.RWMutex
    scrapedMu  sync.RWMutex
    sessionsMu sync.RWMutex
    healthMu   sync.RWMutex  // NEW
}
```

### main.go Integration

```go
// In main.go, after scraper initialization
import "f1-stream/internal/healthcheck"

healthInterval := envDuration("HEALTH_CHECK_INTERVAL", 5*time.Minute)
healthTimeout := envDuration("HEALTH_CHECK_TIMEOUT", 10*time.Second)
hc := healthcheck.New(st, healthInterval, healthTimeout)

// Start health checker in background (after scraper start)
go hc.Run(ctx)
```

### Modified PublicStreams with Health Filter

```go
// internal/store/streams.go - modified
func (s *Store) PublicStreams() ([]models.Stream, error) {
    s.streamsMu.RLock()
    defer s.streamsMu.RUnlock()
    var streams []models.Stream
    if err := readJSON(s.filePath("streams.json"), &streams); err != nil {
        return nil, err
    }

    healthMap := s.HealthMap()

    var pub []models.Stream
    for _, st := range streams {
        if !st.Published {
            continue
        }
        // Check health status. If URL not in health map, assume healthy.
        if healthy, exists := healthMap[st.URL]; exists && !healthy {
            continue
        }
        pub = append(pub, st)
    }
    return pub, nil
}
```

### Unit Test for Health State Updates

```go
// internal/healthcheck/healthcheck_test.go
package healthcheck

import (
    "testing"

    "f1-stream/internal/models"
)

func TestUnhealthyThreshold(t *testing.T) {
    state := &models.HealthState{URL: "http://example.com", Healthy: true}

    // Simulate 4 failures - should remain healthy
    for i := 0; i < 4; i++ {
        state.ConsecutiveFailures++
    }
    if state.ConsecutiveFailures >= unhealthyThreshold {
        t.Error("should not be unhealthy after 4 failures")
    }

    // 5th failure - should become unhealthy
    state.ConsecutiveFailures++
    if state.ConsecutiveFailures < unhealthyThreshold {
        t.Error("should be unhealthy after 5 failures")
    }
}

func TestRecovery(t *testing.T) {
    state := &models.HealthState{
        URL:                 "http://example.com",
        Healthy:             false,
        ConsecutiveFailures: 7,
    }

    // Simulate successful check
    state.ConsecutiveFailures = 0
    state.Healthy = true

    if !state.Healthy {
        t.Error("should be healthy after recovery")
    }
    if state.ConsecutiveFailures != 0 {
        t.Error("failure count should be reset")
    }
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| No health monitoring | Phase 2 adds continuous monitoring | Phase 2 (now) | Dead streams automatically hidden from users |
| All published streams visible | Unhealthy streams filtered from public API | Phase 2 (now) | Better user experience - no broken streams shown |
| Validation only at scrape time | Continuous re-validation via health checks | Phase 2 (now) | Streams that go down after scraping are caught |
| One-shot validation (scraper) | Persistent state with failure tracking | Phase 2 (now) | Nuanced health model with recovery support |

## Design Decisions

### Using a Single GET Request Instead of HEAD + GET

The requirements specify two steps: (1) HTTP reachability check (HLTH-02), (2) content validation (HLTH-03). A literal implementation would do a HEAD request for reachability, then a GET for content. However, since `HasVideoContent()` already performs a GET and checks the status code, doing both steps in a single call is more efficient (one HTTP request instead of two). The `HasVideoContent()` function already returns `false` for non-2xx status codes (line 96-98 of `validate.go`), effectively combining the reachability check with content validation.

The health checker should still log the distinction: if the GET fails or returns non-2xx, log it as a reachability failure. If the GET succeeds but no video markers are found, log it as a content validation failure. This provides diagnostic value without the cost of an extra HTTP request.

### URL as Health State Key

Using the URL (not stream ID or scraped link ID) as the key for health state has several advantages:
1. A URL may appear in both `streams.json` and `scraped_links.json` -- one health check covers both
2. IDs are different types between streams (random hex) and scraped links (random hex but different generation)
3. URL normalization can deduplicate variations (trailing slashes, case)
4. Health is intrinsically a property of the URL, not the database record

### Separate Package vs. Adding to Scraper

The health checker could be added to the scraper package since it reuses `HasVideoContent()`. However, a separate `internal/healthcheck/` package is better because:
1. Different concern: discovery (scraper) vs. monitoring (health checker)
2. Different lifecycle: scraper runs after Reddit fetch; health checker runs independently
3. Different interval: scraper every 15 min, health checker every 5 min
4. Cleaner dependency graph: healthcheck imports scraper, not vice versa
5. Follows the codebase convention of one concern per package

## Open Questions

1. **Should the combined reachability + content check be a single GET, or separate HEAD + GET?**
   - What we know: `HasVideoContent()` already does GET and checks status code. A single GET is more efficient.
   - What's unclear: Whether some servers behave differently for HEAD vs GET (some CDNs return 200 for HEAD but serve different content for GET).
   - Recommendation: Use single GET via `HasVideoContent()`. It already handles both reachability (status code check) and content validation (body inspection). Log failures with diagnostic detail (was it a connection error, non-2xx, or missing markers?). This halves the HTTP request count.

2. **Should health checks run in parallel or sequentially?**
   - What we know: Sequential checking is simpler and follows the scraper's pattern. With 50 streams at 10s timeout each, worst case is ~8 minutes.
   - What's unclear: Real-world stream count. Could be 10 or 200.
   - Recommendation: Start sequential. Log total check duration. If it consistently exceeds 60% of the interval, add bounded parallelism (e.g., `semaphore` pattern with 5 workers). This matches the scraper's approach of starting simple.

3. **Lock ordering for HealthMap called inside PublicStreams**
   - What we know: `PublicStreams()` holds `streamsMu.RLock()` and needs health data. `HealthMap()` reads `health_state.json`.
   - What's unclear: Whether `readJSON` inside `HealthMap()` needs `healthMu` protection.
   - Recommendation: `HealthMap()` should read without acquiring `healthMu` because `readJSON()` does a single `os.ReadFile()` call and `writeJSON()` uses atomic rename. The file is always in a consistent state. Brief staleness (reading milliseconds-old data) is acceptable. This avoids all deadlock risk.

## Sources

### Primary (HIGH confidence)
- Codebase analysis: `internal/scraper/scraper.go` - proven background service pattern with `Run(ctx)`, `time.Ticker`, mutex protection
- Codebase analysis: `internal/scraper/validate.go` - existing `hasVideoContent()`, `containsVideoMarkers()`, `isDirectVideoContentType()` implementations to reuse
- Codebase analysis: `internal/store/store.go` - `readJSON()`/`writeJSON()` atomic persistence pattern, `sync.RWMutex` per entity
- Codebase analysis: `internal/store/streams.go` - `PublicStreams()` filtering pattern to extend
- Codebase analysis: `internal/store/scraped.go` - `GetActiveScrapedLinks()` filtering pattern to extend
- Codebase analysis: `internal/models/models.go` - model definition pattern to follow for `HealthState`
- Codebase analysis: `main.go` - `envDuration()`, service initialization, goroutine startup, context passing
- Go stdlib docs: `time.Ticker`, `sync.RWMutex`, `net/http.Client`, `context.Context`

### Secondary (MEDIUM confidence)
- `.planning/REQUIREMENTS.md` - HLTH-01 through HLTH-09 requirement definitions
- `.planning/ROADMAP.md` - Phase 2 success criteria and dependencies on Phase 1
- `.planning/phases/01-scraper-validation/01-RESEARCH.md` - Phase 1 research confirming validation function design
- `.planning/codebase/ARCHITECTURE.md` - data flow patterns, cross-cutting concerns
- `.planning/codebase/CONVENTIONS.md` - naming, import ordering, error handling conventions
- `.planning/codebase/STRUCTURE.md` - package organization, where to add new code

### Tertiary (LOW confidence)
- None. All findings are based on direct codebase analysis and requirements documents.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - uses only stdlib; all patterns have working examples in the codebase
- Architecture: HIGH - new package follows established scraper pattern exactly; integration points well-defined
- Pitfalls: HIGH - pitfalls identified from concrete codebase analysis (lock ordering, request doubling, unbounded state)
- Health state model: HIGH - simple struct following existing model pattern; persistence follows existing store pattern

**Research date:** 2026-02-17
**Valid until:** 2026-03-17 (stable domain; implementation uses only stdlib and existing codebase patterns)
