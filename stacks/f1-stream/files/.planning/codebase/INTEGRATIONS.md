# External Integrations

**Analysis Date:** 2026-02-17

## APIs & External Services

**Reddit API:**
- Service: Reddit public JSON API (no authentication required)
- What it's used for: Scraping F1 stream links from r/motorsportsstreams2 subreddit
  - Fetches 25 most recent posts: `https://www.reddit.com/r/motorsportsstreams2/new.json?limit=25`
  - Extracts URLs from post titles and comment bodies
  - Filters by F1-related keywords
  - Runs on configurable interval (default 15 minutes)
- Implementation: `internal/scraper/reddit.go`
- Authentication: None - public API endpoint

**HTTP Proxy Service:**
- Service: Internal HTTP proxy for accessing external streams
- What it's used for: Fetching and proxying external stream pages while enforcing security policies
  - Rate limiting: 30 requests/minute per IP with 5-request burst capacity
  - URL validation: Only HTTPS URLs allowed, 2048-character limit
  - Private IP blocking: Blocks requests to loopback, private, and link-local addresses
  - Content transformation: Injects `<base>` tag for relative URL resolution
  - Strips X-Frame-Options and CSP headers to allow iframe embedding
- Implementation: `internal/proxy/proxy.go`
- Endpoint: `GET /proxy?url=[url]`

## Data Storage

**File Storage:**
- Type: Local filesystem (JSON files)
- Location: Configurable via `DATA_DIR` environment variable (default: `/data`)
- Persistence mechanism:
  - Atomic writes using temp-file-then-rename pattern
  - No database server required
  - Files stored in flat structure:
    - `streams.json` - User-submitted and scraped stream links
    - `users.json` - User accounts with WebAuthn credentials
    - `sessions.json` - Active user sessions
    - `scraped.json` - Reddit-scraped links
- Client: Go `encoding/json` standard library with sync.RWMutex for thread-safe access

**Caching:**
- Type: None - file-based storage only
- Session cleanup: Automatic garbage collection every 1 hour

## Authentication & Identity

**Auth Provider:**
- Type: Custom WebAuthn/FIDO2 implementation
- Library: github.com/go-webauthn/webauthn v0.15.0
- Implementation details:
  - Passwordless authentication using WebAuthn standard
  - Registration ceremony: `POST /api/auth/register/begin` → `POST /api/auth/register/finish`
  - Login ceremony: `POST /api/auth/login/begin` → `POST /api/auth/login/finish`
  - Session tokens stored in HTTP-only, SameSite-strict cookies
  - In-memory ceremony data storage with 5-minute expiration
  - Manual admin assignment via `ADMIN_USERNAME` env var
  - First user automatically becomes admin if no `ADMIN_USERNAME` set
- Files: `internal/auth/auth.go`, `internal/auth/context.go`

## Monitoring & Observability

**Error Tracking:**
- Type: None - no external error tracking service
- Implementation: Standard Go logging with `log` package

**Logs:**
- Format: Standard Go log output (stdout)
- Level: Info and error messages
- No centralized logging, no external integration

## CI/CD & Deployment

**Hosting:**
- Platform: Kubernetes (Terraform module at `infra/modules/kubernetes/f1-stream/`)
- Deployment method: Container image

**CI Pipeline:**
- Type: Not detected in this codebase
- Build method: Dockerfile multi-stage build
  - Builder: golang:1.23-alpine with `go mod download`
  - Runtime: alpine:3.20 with minimal dependencies

## Environment Configuration

**Required env vars (with defaults):**
- `LISTEN_ADDR` - Server listen address (default: `:8080`)
- `DATA_DIR` - Data storage directory (default: `/data`)
- `SCRAPE_INTERVAL` - Reddit scraper frequency (default: 15m)
- `SESSION_TTL` - Session expiration (default: 720h)
- `PROXY_TIMEOUT` - Proxy request timeout (default: 10s)
- `WEBAUTHN_RPID` - Relying party ID (default: `localhost`)
- `WEBAUTHN_ORIGIN` - Origin URL list, comma-separated (default: `http://localhost:8080`)
- `WEBAUTHN_DISPLAY_NAME` - UI display name (default: `F1 Stream`)
- `ADMIN_USERNAME` - Optional: pre-set admin username (no default)

**Secrets location:**
- No secrets required - uses WebAuthn credentials stored locally
- CORS origin validation via `WEBAUTHN_ORIGIN` env var

## Webhooks & Callbacks

**Incoming:**
- None detected

**Outgoing:**
- None detected

## Stream Link Sources

**Default Stream URLs (hardcoded in main.go):**
1. `https://wearechecking.live/streams-pages/motorsports` - WeAreChecking Motorsports
2. `https://vipleague.im/formula-1-schedule-streaming-links` - VIPLeague F1
3. `https://www.vipbox.lc/` - VIPBox
4. `https://f1box.me/` - F1Box
5. `https://1stream.vip/formula-1-streams/` - 1Stream F1

---

*Integration audit: 2026-02-17*
