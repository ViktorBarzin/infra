# Phase 1: Scraper Validation - Research

**Researched:** 2026-02-17
**Domain:** HTTP content fetching and HTML video/player content detection in Go
**Confidence:** HIGH

## Summary

Phase 1 adds a validation step to the existing Reddit scraper pipeline. Currently, the scraper extracts ALL URLs from F1-related Reddit posts and saves them to `scraped_links.json` without verifying whether they point to actual stream pages. The validation step will proxy-fetch each extracted URL (reusing the existing proxy's HTTP client pattern) and inspect the HTML response for video/player content markers before saving.

The implementation is straightforward because the codebase already has all the infrastructure needed: HTTP fetching with timeouts (used in both `internal/scraper/reddit.go` and `internal/proxy/proxy.go`), URL validation, and the scraper pipeline with deduplication. The new code is a validation function inserted between URL extraction and saving, operating on the same `[]models.ScrapedLink` type.

**Primary recommendation:** Add a `validateStreamURL` function in a new file `internal/scraper/validate.go` that uses string-based content matching (not full HTML parsing) to detect video markers, with `golang.org/x/net/html` reserved for Phase 4 (video extraction). Keep it simple: fetch the page, lowercase the body, check for known patterns. This avoids adding a dependency for Phase 1 while Phase 2 will reuse the same validation logic for health checks.

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| SCRP-01 | Scraper filters Reddit posts by F1 keywords before extracting URLs (existing behavior, preserve) | Existing `isF1Post()` function in `reddit.go` lines 272-285 handles this. No changes needed -- just ensure the validation step is added AFTER URL extraction, not replacing the keyword filter. |
| SCRP-02 | Scraper validates each extracted URL by proxy-fetching it and checking for video/player content markers | New `validateStreamURL()` function fetches URL with configurable timeout, reads response body, checks for video content markers (see "Video Content Markers" section below for complete list). Reuse existing HTTP client pattern from `reddit.go:88`. |
| SCRP-03 | URLs that don't look like streams (no video markers detected) are discarded before saving | Filter applied in `scraper.go:scrape()` between URL extraction (line 57) and merge/save (line 60). Only URLs passing validation are included in the `links` slice passed to the merge step. |
| SCRP-04 | Validation has a configurable timeout (default 10s) to avoid blocking on slow sites | Add `SCRAPER_VALIDATE_TIMEOUT` environment variable read in `main.go`, passed to `scraper.New()`. Use `context.WithTimeout` on per-URL fetch to enforce deadline. Default 10 seconds. |
</phase_requirements>

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `net/http` | stdlib | HTTP client for fetching URLs | Already used throughout codebase (`reddit.go`, `proxy.go`). No external dependency needed. |
| `strings` | stdlib | Case-insensitive string matching for content markers | Already used extensively. `strings.Contains` on lowercased body is the simplest approach for marker detection. |
| `regexp` | stdlib | Pattern matching for HLS/DASH URLs in page source | Already used in `reddit.go` for URL extraction. Needed for matching `.m3u8` and `.mpd` URL patterns in HTML content. |
| `context` | stdlib | Timeout enforcement per URL validation | Already used in scraper (`scraper.go:Run`). `context.WithTimeout` provides per-request deadline. |
| `io` | stdlib | `io.LimitReader` for response body size limiting | Already used in `proxy.go` and `reddit.go` for body size limits. |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `golang.org/x/net/html` | latest | Full HTML DOM parsing | NOT needed for Phase 1. Reserve for Phase 4 (video source extraction). String matching is sufficient for detection. |
| `sync` | stdlib | WaitGroup for parallel validation | If parallel validation is desired. But sequential is simpler and respects rate limits of target sites. |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| String matching on body | `golang.org/x/net/html` DOM parsing | DOM parsing is more accurate but adds a dependency and complexity. For Phase 1 (detection, not extraction), string matching is sufficient. Phase 4 needs DOM parsing for actual source extraction. |
| Sequential URL validation | `sync.WaitGroup` parallel validation | Parallel is faster but risks triggering rate limits on target sites and complicates error handling. Sequential with timeout is simpler and predictable. |
| Custom HTTP client | Reuse proxy's `*http.Client` | The proxy client has redirect limits and timeout already configured. But the scraper should have its own client with validation-specific timeout. Keep them independent. |

**Installation:**
```bash
# No new dependencies needed for Phase 1. All stdlib.
# golang.org/x/net/html deferred to Phase 4.
```

## Architecture Patterns

### Where Validation Fits in the Pipeline

```
Current flow:
  scrapeReddit() -> []models.ScrapedLink -> merge with existing -> save

New flow:
  scrapeReddit() -> []models.ScrapedLink -> validateLinks() -> []models.ScrapedLink -> merge with existing -> save
```

The validation step is a filter function that takes a slice of scraped links and returns only those that pass validation. This keeps the existing pipeline intact and makes the validation step independently testable.

### Recommended File Structure

```
internal/scraper/
  scraper.go       # Orchestrator (existing, add validateTimeout field + call validateLinks)
  reddit.go        # Reddit API scraping (existing, no changes)
  validate.go      # NEW: validateStreamURL(), validateLinks(), content marker definitions
```

### Pattern 1: Validation as a Filter Function

**What:** A pure filter function that takes `[]models.ScrapedLink` and returns the subset that pass validation.
**When to use:** When adding a validation/filter step to an existing pipeline.
**Example:**

```go
// internal/scraper/validate.go

// validateLinks filters links to only those with video content markers.
// Each URL is fetched with the given timeout and inspected for markers.
func validateLinks(links []models.ScrapedLink, timeout time.Duration) []models.ScrapedLink {
    client := &http.Client{Timeout: timeout}
    var valid []models.ScrapedLink
    for _, link := range links {
        if hasVideoContent(client, link.URL) {
            valid = append(valid, link)
        } else {
            log.Printf("scraper: discarded %s (no video markers)", truncate(link.URL, 60))
        }
    }
    return valid
}

// hasVideoContent fetches a URL and checks for video/player content markers.
func hasVideoContent(client *http.Client, rawURL string) bool {
    req, err := http.NewRequest("GET", rawURL, nil)
    if err != nil {
        return false
    }
    req.Header.Set("User-Agent", userAgent) // reuse existing constant

    resp, err := client.Do(req)
    if err != nil {
        log.Printf("scraper: validate fetch error for %s: %v", truncate(rawURL, 60), err)
        return false
    }
    defer resp.Body.Close()

    // Only inspect HTML responses
    ct := resp.Header.Get("Content-Type")
    if !strings.Contains(ct, "text/html") && !strings.Contains(ct, "application/xhtml") {
        // Could be a direct video file (.m3u8, .mpd, .mp4) which is valid
        if isDirectVideoContentType(ct) {
            return true
        }
        return false
    }

    body, err := io.ReadAll(io.LimitReader(resp.Body, 2*1024*1024)) // 2MB limit for validation
    if err != nil {
        return false
    }

    return containsVideoMarkers(strings.ToLower(string(body)))
}
```

### Pattern 2: Configuration Via Struct Field

**What:** Pass validation timeout through the existing `Scraper` struct, configured from `main.go` env vars.
**When to use:** Following existing codebase pattern where all config flows through `main.go` -> constructor.
**Example:**

```go
// internal/scraper/scraper.go
type Scraper struct {
    store           *store.Store
    interval        time.Duration
    validateTimeout time.Duration // NEW
    mu              sync.Mutex
}

func New(s *store.Store, interval time.Duration, validateTimeout time.Duration) *Scraper {
    return &Scraper{store: s, interval: interval, validateTimeout: validateTimeout}
}

// In main.go:
validateTimeout := envDuration("SCRAPER_VALIDATE_TIMEOUT", 10*time.Second)
sc := scraper.New(st, scrapeInterval, validateTimeout)
```

### Pattern 3: Integration Point in scrape()

**What:** Call validateLinks between scrapeReddit return and merge step.
**When to use:** Minimal change to existing scrape flow.
**Example:**

```go
// In scraper.go:scrape() - between lines 57 and 60
links, err := scrapeReddit()
if err != nil {
    // ... existing error handling
}
log.Printf("scraper: reddit scrape completed in %v, got %d links", time.Since(start).Round(time.Millisecond), len(links))

// NEW: validate links before merging
if len(links) > 0 {
    validated := validateLinks(links, s.validateTimeout)
    log.Printf("scraper: validated %d/%d links as streams", len(validated), len(links))
    links = validated
}

// Continue with existing merge logic...
```

### Anti-Patterns to Avoid

- **Fetching URLs inside the Reddit API loop:** Validation should happen after all URLs are collected from Reddit, not interleaved with Reddit API calls. This keeps the Reddit API calls fast and avoids mixing rate-limit concerns.
- **Using the proxy's HTTP handler for internal validation:** The proxy (`internal/proxy/proxy.go`) is designed as an HTTP handler for client-facing requests with IP-based rate limiting. The scraper should use its own HTTP client without rate limiting since it is a trusted internal caller.
- **Modifying the ScrapedLink model to track validation state:** For Phase 1, validation is a binary filter (pass or discard). Adding validation metadata to the model is premature and adds complexity to the store layer. If needed in Phase 2 for health checking, it can be added then.
- **Full HTML DOM parsing for detection:** Using `golang.org/x/net/html` to parse the full DOM tree just to detect presence of video tags is overkill. String matching on lowercased HTML body is sufficient for detection. DOM parsing is needed in Phase 4 for actual source URL extraction.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| HTTP fetching with timeout | Custom TCP client | `net/http.Client` with `Timeout` field | stdlib handles redirects, TLS, timeouts, connection pooling |
| HTML content inspection | Full DOM parser | `strings.Contains` on lowercased body | Detection (yes/no) does not need structural parsing; string matching is faster and simpler |
| URL scheme validation | Manual string prefix check | `net/url.Parse` + scheme check | Already used in codebase; handles edge cases |
| Concurrent timeout enforcement | Manual goroutine + channel | `context.WithTimeout` + `http.NewRequestWithContext` | stdlib integration; cancels in-flight requests properly |

**Key insight:** Phase 1 is a detection problem (does this page look like a stream?), not an extraction problem (what is the stream URL?). Detection can be done with string matching. Extraction (Phase 4) needs DOM parsing.

## Video Content Markers

### HIGH confidence markers (any one of these strongly indicates a stream page)

**HTML Tags:**
- `<video` - HTML5 video element
- `<source` with `type="application/x-mpegurl"` or `type="application/dash+xml"` - HLS/DASH sources
- `<iframe` with src containing known player domains

**HLS/DASH Manifest References:**
- `.m3u8` - HLS manifest file extension
- `.mpd` - DASH manifest file extension
- `application/x-mpegurl` - HLS MIME type
- `application/vnd.apple.mpegurl` - Alternative HLS MIME type
- `application/dash+xml` - DASH MIME type

**Player Library References:**
- `hls.js` or `hls.min.js` - HLS.js player library
- `dash.js` or `dash.all.min.js` - DASH.js player library
- `video.js` or `video.min.js` or `videojs` - Video.js player
- `jwplayer` - JW Player
- `clappr` - Clappr player
- `flowplayer` - Flowplayer
- `plyr` - Plyr player
- `shaka-player` or `shaka` - Google Shaka Player
- `mediaelement` - MediaElement.js
- `fluidplayer` - Fluid Player

**Direct Video File Extensions in URLs:**
- `.mp4` - MPEG-4 video
- `.webm` - WebM video
- `.ts` (in context of `.m3u8` references) - MPEG-TS segments

### MEDIUM confidence markers (suggestive but not conclusive)

- `player` (as class, id, or variable name in context of video)
- `stream` (in context of video-related markup)
- `embed` (in context of video players)

### Implementation Strategy

Use a tiered approach:
1. First check for HIGH confidence markers (any single match = valid)
2. Do NOT use MEDIUM confidence markers alone (too many false positives)
3. Direct video content types in HTTP response (`video/mp4`, `application/x-mpegurl`, etc.) are valid without HTML inspection

```go
// Content markers to check (case-insensitive, checked against lowercased body)
var videoMarkers = []string{
    // HTML5 video element
    "<video",
    // HLS markers
    ".m3u8",
    "application/x-mpegurl",
    "application/vnd.apple.mpegurl",
    // DASH markers
    ".mpd",
    "application/dash+xml",
    // Player libraries
    "hls.js", "hls.min.js",
    "dash.js", "dash.all.min.js",
    "video.js", "video.min.js", "videojs",
    "jwplayer",
    "clappr",
    "flowplayer",
    "plyr",
    "shaka-player",
    "mediaelement",
    "fluidplayer",
}

// Direct video content types (check Content-Type header)
var videoContentTypes = []string{
    "video/",
    "application/x-mpegurl",
    "application/vnd.apple.mpegurl",
    "application/dash+xml",
    "application/mpegurl",
}

func containsVideoMarkers(loweredBody string) bool {
    for _, marker := range videoMarkers {
        if strings.Contains(loweredBody, marker) {
            return true
        }
    }
    return false
}

func isDirectVideoContentType(ct string) bool {
    ct = strings.ToLower(ct)
    for _, vct := range videoContentTypes {
        if strings.Contains(ct, vct) {
            return true
        }
    }
    return false
}
```

## Common Pitfalls

### Pitfall 1: Blocking the Scrape Cycle on Slow/Unresponsive URLs

**What goes wrong:** A single URL that times out at 10s, multiplied by 50 URLs per scrape cycle, means the validation step takes 500 seconds (8+ minutes). With a 15-minute scrape interval, validation could overlap with the next cycle.
**Why it happens:** Sequential validation with per-URL timeout does not have a total budget for the validation step.
**How to avoid:** The per-URL timeout (SCRP-04) handles individual slowness. Additionally, consider logging total validation time. The mutex in `scraper.go:scrape()` already prevents concurrent scrapes, so overlap is safe (next scrape just waits). With typical scrape volumes (5-20 new URLs per cycle), even worst case (20 * 10s = 200s) is well within the 15-minute interval.
**Warning signs:** Scrape logs showing validation taking longer than half the scrape interval.

### Pitfall 2: False Negatives from JavaScript-Rendered Pages

**What goes wrong:** Many streaming sites load their video player via JavaScript. An HTTP fetch gets the initial HTML which may not contain `<video>` tags or player references -- those are injected by JS after page load.
**Why it happens:** HTTP fetching returns raw HTML; no JavaScript execution.
**How to avoid:** This is an accepted limitation per the requirements doc ("Full browser automation (Puppeteer/Playwright)" is Out of Scope). The marker list includes JavaScript library references (e.g., `hls.js`, `video.js`) which ARE present in the raw HTML even before execution. Most streaming sites include their player library in `<script>` tags in the initial HTML. The marker list is designed to catch these references.
**Warning signs:** Known good stream URLs being discarded. Monitor discard rate in logs.

### Pitfall 3: HTTP vs HTTPS URL Handling

**What goes wrong:** The existing proxy only supports HTTPS URLs (line 68 in `proxy.go`), but scraped URLs may be HTTP. If the validator only accepts HTTPS, valid HTTP stream URLs get discarded.
**Why it happens:** The proxy has a stricter security requirement (client-facing) than the scraper (internal validation).
**How to avoid:** The scraper validator should accept both HTTP and HTTPS URLs for fetching. The proxy's HTTPS restriction is appropriate for its purpose but should not be inherited by the validator.
**Warning signs:** All HTTP URLs being discarded.

### Pitfall 4: Redirect Chains Leading to Non-Stream Content

**What goes wrong:** A URL redirects through several pages (ads, link shorteners) before reaching the actual stream page. The HTTP client follows redirects (Go default: up to 10), but the intermediate pages may not have video markers.
**Why it happens:** Streaming links from Reddit often go through shorteners or ad-redirect chains.
**How to avoid:** Go's `http.Client` follows redirects by default (up to 10). The validation checks the FINAL response after redirects. Set a reasonable redirect limit (3, matching proxy's limit) to avoid infinite chains. The timeout applies to the entire chain, so slow redirect chains will timeout.
**Warning signs:** Timeout errors on URLs that resolve fine in a browser.

### Pitfall 5: Large Response Bodies Causing Memory Pressure

**What goes wrong:** A streaming site returns a huge HTML page (or a direct video file), and the validator reads the entire body into memory.
**Why it happens:** No body size limit on validation fetches.
**How to avoid:** Use `io.LimitReader` (already a pattern in the codebase). 2MB is sufficient for detecting markers in HTML. For direct video content types, the Content-Type header check is sufficient -- no need to read the body.
**Warning signs:** Memory spikes during scrape cycles.

### Pitfall 6: Changing the `scraper.New()` Signature Breaks Existing Call Site

**What goes wrong:** Adding `validateTimeout` parameter to `New()` changes its signature, breaking the call in `main.go`.
**Why it happens:** Go does not have optional parameters.
**How to avoid:** Update both `New()` in `scraper.go` and the call site in `main.go` simultaneously. This is a simple, predictable change. Alternative: use options pattern, but that is overkill for adding one field.
**Warning signs:** Compilation error -- easily caught.

## Code Examples

### Complete validateLinks Implementation

```go
// internal/scraper/validate.go
package scraper

import (
    "io"
    "log"
    "net/http"
    "strings"
    "time"

    "f1-stream/internal/models"
)

// videoMarkers are case-insensitive strings that indicate video/player content.
// Checked against lowercased HTML body.
var videoMarkers = []string{
    "<video",
    ".m3u8",
    "application/x-mpegurl",
    "application/vnd.apple.mpegurl",
    ".mpd",
    "application/dash+xml",
    "hls.js", "hls.min.js",
    "dash.js", "dash.all.min.js",
    "video.js", "video.min.js", "videojs",
    "jwplayer",
    "clappr",
    "flowplayer",
    "plyr",
    "shaka-player",
    "mediaelement",
    "fluidplayer",
}

// videoContentTypes are Content-Type prefixes that indicate direct video content.
var videoContentTypes = []string{
    "video/",
    "application/x-mpegurl",
    "application/vnd.apple.mpegurl",
    "application/dash+xml",
}

const validateBodyLimit = 2 * 1024 * 1024 // 2MB

// validateLinks filters links to only those whose URLs contain video content markers.
func validateLinks(links []models.ScrapedLink, timeout time.Duration) []models.ScrapedLink {
    client := &http.Client{
        Timeout: timeout,
        CheckRedirect: func(req *http.Request, via []*http.Request) error {
            if len(via) >= 3 {
                return http.ErrUseLastResponse
            }
            return nil
        },
    }

    var valid []models.ScrapedLink
    for _, link := range links {
        if hasVideoContent(client, link.URL) {
            valid = append(valid, link)
            log.Printf("scraper: validated %s (video markers found)", truncate(link.URL, 60))
        } else {
            log.Printf("scraper: discarded %s (no video markers)", truncate(link.URL, 60))
        }
    }
    return valid
}

func hasVideoContent(client *http.Client, rawURL string) bool {
    req, err := http.NewRequest("GET", rawURL, nil)
    if err != nil {
        return false
    }
    req.Header.Set("User-Agent", userAgent)

    resp, err := client.Do(req)
    if err != nil {
        log.Printf("scraper: validate fetch error for %s: %v", truncate(rawURL, 60), err)
        return false
    }
    defer resp.Body.Close()

    if resp.StatusCode < 200 || resp.StatusCode >= 400 {
        return false
    }

    ct := strings.ToLower(resp.Header.Get("Content-Type"))

    // Check if response is a direct video content type
    for _, vct := range videoContentTypes {
        if strings.Contains(ct, vct) {
            return true
        }
    }

    // Only inspect HTML responses for markers
    if !strings.Contains(ct, "text/html") && !strings.Contains(ct, "application/xhtml") {
        return false
    }

    body, err := io.ReadAll(io.LimitReader(resp.Body, validateBodyLimit))
    if err != nil {
        return false
    }

    return containsVideoMarkers(strings.ToLower(string(body)))
}

func containsVideoMarkers(loweredBody string) bool {
    for _, marker := range videoMarkers {
        if strings.Contains(loweredBody, marker) {
            return true
        }
    }
    return false
}
```

### Integration in scraper.go

```go
// scraper.go - modified scrape() method
func (s *Scraper) scrape() {
    s.mu.Lock()
    defer s.mu.Unlock()

    start := time.Now()
    log.Println("scraper: starting scrape")
    links, err := scrapeReddit()
    if err != nil {
        log.Printf("scraper: error after %v: %v", time.Since(start).Round(time.Millisecond), err)
        return
    }
    log.Printf("scraper: reddit scrape completed in %v, got %d links", time.Since(start).Round(time.Millisecond), len(links))

    // Validate links - only keep those with video content markers
    if len(links) > 0 {
        validated := validateLinks(links, s.validateTimeout)
        log.Printf("scraper: validated %d/%d links as streams", len(validated), len(links))
        links = validated
    }

    // Rest of existing merge logic unchanged...
}
```

### Configuration in main.go

```go
// main.go additions
validateTimeout := envDuration("SCRAPER_VALIDATE_TIMEOUT", 10*time.Second)
sc := scraper.New(st, scrapeInterval, validateTimeout)
```

### Unit Test for containsVideoMarkers

```go
// internal/scraper/validate_test.go
package scraper

import "testing"

func TestContainsVideoMarkers(t *testing.T) {
    tests := []struct {
        name     string
        body     string
        expected bool
    }{
        {"video tag", `<div><video src="stream.mp4"></video></div>`, true},
        {"hls manifest", `var url = "https://cdn.example.com/live.m3u8";`, true},
        {"dash manifest", `<source src="stream.mpd" type="application/dash+xml">`, true},
        {"hls.js library", `<script src="/js/hls.min.js"></script>`, true},
        {"video.js library", `<script src="https://cdn.example.com/video.js"></script>`, true},
        {"jwplayer", `<div id="jwplayer-container"></div><script>jwplayer("jwplayer-container")</script>`, true},
        {"no markers", `<html><body><p>Hello world</p></body></html>`, false},
        {"reddit link page", `<html><body><a href="https://example.com">Click here</a></body></html>`, false},
        {"blog post", `<html><body><article>F1 race results...</article></body></html>`, false},
    }

    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            result := containsVideoMarkers(tt.body)
            if result != tt.expected {
                t.Errorf("containsVideoMarkers(%q) = %v, want %v", truncate(tt.body, 40), result, tt.expected)
            }
        })
    }
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Save all URLs from F1 posts | Will validate each URL before saving | Phase 1 (now) | Eliminates junk links at the source |
| No content inspection | String-based marker detection | Phase 1 (now) | Simple, fast, no external dependencies |
| Static marker list | Static marker list (sufficient for now) | - | May need updating as new players emerge; easily extensible |

**Why not use browser automation:**
The REQUIREMENTS.md explicitly marks "Full browser automation (Puppeteer/Playwright)" as Out of Scope. HTTP-based checks with string matching catch the majority of stream pages because player library `<script>` tags are present in raw HTML even before JavaScript execution.

## Open Questions

1. **How many URLs per scrape cycle will need validation?**
   - What we know: The subreddit listing fetches 25 posts, filters by F1 keywords. Typical F1-related posts might yield 5-20 unique URLs per cycle after deduplication and domain filtering.
   - What's unclear: Real-world distribution. Could be 2 URLs or 50.
   - Recommendation: Log validation counts in production. The sequential approach with 10s timeout per URL handles up to ~90 URLs within the 15-minute scrape interval (worst case).

2. **Should already-validated URLs be re-validated on subsequent scrape cycles?**
   - What we know: The current merge step deduplicates by URL -- existing URLs are not re-processed. Validation runs only on newly discovered URLs.
   - What's unclear: Whether a URL that failed validation last cycle should be retried.
   - Recommendation: No retry needed for Phase 1. Failed URLs are simply not saved. If the URL appears again in a future scrape, it will be a "new" URL (not yet in scraped.json) and get validated again naturally.

3. **Will the marker list need frequent updates?**
   - What we know: Major player libraries (HLS.js, Video.js, JW Player) are well-established and their names are stable.
   - What's unclear: Whether niche streaming sites use custom players with no recognizable markers.
   - Recommendation: Start with the current list. Monitor discard rate in logs. Add markers if known-good sites are being discarded. The list is a simple string slice, trivially extensible.

## Sources

### Primary (HIGH confidence)
- Codebase analysis: `internal/scraper/scraper.go`, `internal/scraper/reddit.go`, `internal/proxy/proxy.go` - existing patterns for HTTP fetching, URL processing, pipeline structure
- Codebase analysis: `internal/models/models.go` - ScrapedLink type definition
- Codebase analysis: `main.go` - env var pattern, dependency initialization
- Go stdlib docs: `net/http`, `strings`, `io`, `context` packages
- `golang.org/x/net/html` package API (verified via pkg.go.dev) - confirmed `html.Parse`, `Node.Descendants()`, `atom.Video` available. Reserved for Phase 4.

### Secondary (MEDIUM confidence)
- `.planning/REQUIREMENTS.md` - phase requirements, out-of-scope decisions
- `.planning/ROADMAP.md` - phase dependencies (Phase 2 reuses validation logic)
- `.planning/codebase/ARCHITECTURE.md` - data flow, cross-cutting concerns

### Tertiary (LOW confidence)
- Video player library names (hls.js, video.js, jwplayer, etc.) - based on widely known ecosystem knowledge. The specific set of markers may need tuning based on real-world stream sites.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - uses only stdlib; all patterns already exist in codebase
- Architecture: HIGH - minimal change to existing pipeline; clear integration point
- Pitfalls: HIGH - pitfalls are well-understood; mitigations use existing codebase patterns
- Video markers: MEDIUM - marker list covers major players but may miss niche sites; easily extensible

**Research date:** 2026-02-17
**Valid until:** 2026-03-17 (stable domain; marker list may need periodic updates)
