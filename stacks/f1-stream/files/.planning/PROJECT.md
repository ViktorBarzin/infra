# F1 Stream

## What This Is

A self-hosted web app that aggregates live Formula 1 streaming links from Reddit and user submissions, presenting them in a clean UI with embedded iframes. It scrapes r/motorsportsstreams2, allows users to submit their own stream URLs, and provides admin controls for content moderation. Built in Go with vanilla JS frontend, deployed on Kubernetes.

## Core Value

Users can find working F1 streams quickly — the app automatically discovers, validates, and surfaces healthy streams while removing dead ones.

## Requirements

### Validated

<!-- Shipped and confirmed valuable. Inferred from existing codebase. -->

- ✓ Reddit scraper polls r/motorsportsstreams2 for F1-related posts — existing
- ✓ URL extraction from post bodies and comment trees — existing
- ✓ F1 keyword filtering with negative keyword exclusion — existing
- ✓ Domain filtering (reddit, imgur, youtube, twitter excluded) — existing
- ✓ Deduplication via normalized URLs — existing
- ✓ User stream submission (anonymous + authenticated) — existing
- ✓ WebAuthn passwordless authentication — existing
- ✓ Admin approval workflow for user-submitted streams — existing
- ✓ HTTP proxy with rate limiting, private IP blocking, CSP stripping — existing
- ✓ Static frontend with iframe-based stream viewing — existing
- ✓ Default seed streams on first run — existing
- ✓ Stale link cleanup (24h) — existing
- ✓ Client-side health sort (reorder by reachability) — existing

### Active

<!-- Current scope. Building toward these. -->

- [ ] Scraper validates extracted URLs look like actual streams (video/player content), not random links
- [ ] Server-side health checker runs every 5 minutes against all known streams
- [ ] Health check: HTTP reachability check first, then proxy-fetch to detect video/player markers
- [ ] Configurable health check timeout
- [ ] Streams marked unhealthy after 5 consecutive check failures get hidden from public page
- [ ] Unhealthy streams retried on each check cycle — restored if they recover
- [ ] Scraped streams that pass health checks auto-published to main streams page
- [ ] Dead streams dynamically removed from the page without manual intervention
- [ ] Health status persisted (failure count, last check time, healthy/unhealthy state)

### Out of Scope

- Database migration (SQLite/PostgreSQL) — file-based storage is fine for this scope
- Multiple subreddit sources — stick with r/motorsportsstreams2 for now
- Real-time WebSocket push of stream status — polling is sufficient
- Mobile app — web-only
- OAuth/social login — WebAuthn is sufficient

## Context

- The app runs on a personal Kubernetes cluster, deployed via Terraform
- Single-user / small-group usage — performance at scale is not a concern
- The existing client-side `sortStreamsByHealth` does a basic `no-cors` fetch but can't inspect content; server-side checks via the proxy can do deeper validation
- Reddit's public JSON API requires no auth but rate-limits aggressively; the scraper already handles 429s with backoff
- Stream sites frequently go down, change URLs, or get taken down — health checking is essential for a good UX

## Constraints

- **Tech stack**: Go backend, vanilla JS frontend — no new frameworks or dependencies unless strictly necessary
- **Storage**: File-based JSON — no database
- **Deployment**: Docker container on Kubernetes, single replica
- **Reddit API**: Public JSON endpoints, must respect rate limits (1 req/sec delay already in place)

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Server-side health checks over client-side only | Client can't inspect response content (CORS); server proxy can detect video markers | — Pending |
| 5 consecutive failures before hiding | Avoids flapping — streams that are temporarily down aren't immediately removed | — Pending |
| Auto-publish scraped streams that pass health | Reduces manual admin work; the health check is the quality gate | — Pending |
| Health check every 5 minutes | Balances freshness vs. load — streams don't change status that frequently | — Pending |

---
*Last updated: 2026-02-17 after initialization*
