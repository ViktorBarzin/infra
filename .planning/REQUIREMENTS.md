# Requirements: F1 Streaming Service

**Defined:** 2026-02-23
**Core Value:** When an F1 session is live, users open one URL and immediately see working streams — no hunting for links.

## v1 Requirements

Requirements for initial release. Each maps to roadmap phases.

### Schedule

- [ ] **SCHED-01**: System auto-pulls F1 race calendar with all official sessions (FP1-3, Qualifying, Sprint, Race) from OpenF1/Jolpica API

### Extraction

- [ ] **EXTR-01**: Extractor framework with plugin-per-site pattern — each site is an independent extractor class
- [ ] **EXTR-02**: Extractors bypass site protections (CSRF tokens, redirect chains, JS-computed URLs) to get final HLS/m3u8 source URLs
- [ ] **EXTR-03**: Background polling scrapes configured sites periodically, caches results in-memory
- [ ] **EXTR-04**: Auto-refresh expired CDN tokens mid-stream without interrupting playback
- [ ] **EXTR-05**: Fallback ordering across multiple sources — rank by reliability, try next on failure

### Proxy

- [ ] **PRXY-01**: HLS proxy with full m3u8 URL rewriting at all playlist levels (master → variant → segments)
- [ ] **PRXY-02**: CORS headers on all proxy endpoints for browser playback
- [ ] **PRXY-03**: Chunked segment relay — stream bytes through, never buffer full segments in memory
- [ ] **PRXY-04**: Quality selection — expose available stream variants, let users pick quality
- [ ] **PRXY-05**: CDN token refresh loop to keep streams alive during 2+ hour sessions

### Health

- [ ] **HLTH-01**: Pre-display verification — check extracted streams are live and playable before showing to users
- [ ] **HLTH-02**: Dead stream marking — tag broken/offline streams so users don't click them
- [ ] **HLTH-03**: Quality metrics — track bitrate, buffering ratio, and latency per active stream

### Frontend

- [ ] **FRNT-01**: Stream picker — display available streams per live session, user selects one
- [ ] **FRNT-02**: Embedded HLS player using hls.js for in-browser playback
- [ ] **FRNT-03**: Multi-stream layout — watch multiple streams side by side (e.g., race feed + onboard camera)

### Deployment

- [ ] **DEPL-01**: K8s deployment via Terragrunt stack following existing infra patterns
- [ ] **DEPL-02**: NFS storage for persistent data (schedule cache, extractor config)

## v2 Requirements

Deferred to future release. Tracked but not in current roadmap.

### Schedule

- **SCHED-02**: Session countdown timer and live/upcoming/past status indicators
- **SCHED-03**: Pre/post shows, press conferences in schedule (requires per-site detection)

### Frontend

- **FRNT-04**: Live timing overlay with sector times and positions

## Out of Scope

Explicitly excluded. Documented to prevent scope creep.

| Feature | Reason |
|---------|--------|
| User authentication | Security by obscurity, private URL |
| Community features (chat, comments) | Just streams, not a social platform |
| DVR/recording | Live viewing only |
| Mobile app | Web-only |
| Official F1TV integration | Unofficial re-streams only |
| Headless browser extraction | Custom per-site extractors are lighter and more reliable |

## Traceability

Which phases cover which requirements. Updated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| SCHED-01 | — | Pending |
| EXTR-01 | — | Pending |
| EXTR-02 | — | Pending |
| EXTR-03 | — | Pending |
| EXTR-04 | — | Pending |
| EXTR-05 | — | Pending |
| PRXY-01 | — | Pending |
| PRXY-02 | — | Pending |
| PRXY-03 | — | Pending |
| PRXY-04 | — | Pending |
| PRXY-05 | — | Pending |
| HLTH-01 | — | Pending |
| HLTH-02 | — | Pending |
| HLTH-03 | — | Pending |
| FRNT-01 | — | Pending |
| FRNT-02 | — | Pending |
| FRNT-03 | — | Pending |
| DEPL-01 | — | Pending |
| DEPL-02 | — | Pending |

**Coverage:**
- v1 requirements: 19 total
- Mapped to phases: 0
- Unmapped: 19 ⚠️

---
*Requirements defined: 2026-02-23*
*Last updated: 2026-02-23 after initial definition*
