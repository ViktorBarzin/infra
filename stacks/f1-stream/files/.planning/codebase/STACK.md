# Technology Stack

**Analysis Date:** 2026-02-17

## Languages

**Primary:**
- Go 1.24.1 - Backend application and main server logic

**Secondary:**
- HTML/CSS/JavaScript - Frontend UI

## Runtime

**Environment:**
- Go runtime (compiled binary)

**Container Runtime:**
- Docker/Alpine Linux (3.20) - Production deployment target
- Multi-stage Dockerfile with golang:1.23-alpine builder

**Package Manager:**
- Go modules (go.mod/go.sum)

## Frameworks

**Core:**
- Standard Go `net/http` - HTTP server and routing
  - Native http.ServeMux for route handling (Go 1.22+ pattern routing)
  - Native http.FileServer for static file serving
  - Native http.Handler interface for middleware

**Authentication:**
- github.com/go-webauthn/webauthn v0.15.0 - WebAuthn/FIDO2 authentication
  - Handles registration and login ceremonies
  - Supports multiple credential types

**Frontend:**
- HTML5 - Markup
- CSS - Styling (Pico CSS framework for minimal styling)
- Vanilla JavaScript - Client-side interactivity (no framework detected)

## Key Dependencies

**Critical:**
- github.com/go-webauthn/webauthn v0.15.0 - Passwordless authentication via WebAuthn
  - Includes transitive dependencies:
    - github.com/go-webauthn/x v0.1.26 - WebAuthn extension support
    - github.com/golang-jwt/jwt/v5 v5.3.0 - JWT token handling
    - github.com/google/go-tpm v0.9.6 - TPM support for credentials
    - github.com/fxamacker/cbor/v2 v2.9.0 - CBOR encoding/decoding
    - github.com/go-viper/mapstructure/v2 v2.4.0 - Configuration mapping
    - github.com/google/uuid v1.6.0 - UUID generation
    - golang.org/x/crypto v0.43.0 - Cryptographic primitives
    - golang.org/x/sys v0.37.0 - System-level primitives

**Infrastructure:**
- None detected (no external databases, queues, or third-party services in go.mod)
- File-based storage only

## Configuration

**Environment Variables:**
- `LISTEN_ADDR` - Server listen address (default: `:8080`)
- `DATA_DIR` - Data storage directory (default: `/data`)
- `SCRAPE_INTERVAL` - Reddit scraper interval (default: 15 minutes)
- `ADMIN_USERNAME` - Admin account username (optional)
- `SESSION_TTL` - Session expiration time (default: 720 hours)
- `PROXY_TIMEOUT` - HTTP proxy request timeout (default: 10 seconds)
- `WEBAUTHN_RPID` - WebAuthn relying party ID (default: `localhost`)
- `WEBAUTHN_ORIGIN` - WebAuthn origin URL (default: `http://localhost:8080`)
- `WEBAUTHN_DISPLAY_NAME` - WebAuthn display name (default: `F1 Stream`)

**Build:**
- `Dockerfile` - Multi-stage Docker build
  - Builder stage: golang:1.23-alpine with CGO_ENABLED=0
  - Runtime stage: alpine:3.20 with ca-certificates
  - Exposes port 8080

## Platform Requirements

**Development:**
- Go 1.24.1 or compatible
- Unix-like shell (bash/zsh) for build scripts
- Optional: Docker for containerized development

**Production:**
- Kubernetes cluster (Terraform module structure suggests K8s deployment)
- Persistent volume for `/data` directory
- Port 8080 exposed for HTTP traffic
- ca-certificates for HTTPS proxying

## Storage

**Data Persistence:**
- File-based JSON storage in `DATA_DIR`
- Files: `streams.json`, `users.json`, `sessions.json`, `scraped.json`
- Atomic writes using temp-file-then-rename pattern (`writeJSON` function in `internal/store/store.go`)

## External Data Sources

**Reddit API:**
- URL: `https://www.reddit.com/r/motorsportsstreams2/new.json?limit=25`
- No authentication required (public subreddit)
- Used for scraping F1 stream links

---

*Stack analysis: 2026-02-17*
