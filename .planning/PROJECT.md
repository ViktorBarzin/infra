# F1 Streaming Service

## What This Is

A private F1 streaming aggregation service that auto-scrapes specific streaming sites, extracts actual video source URLs through custom per-site extractors (bypassing obfuscation, CSRF, and redirect chains), and proxies the streams through a unified Svelte web app. Deployed on the existing K8s cluster.

## Core Value

When an F1 session is live, users open one URL and immediately see working streams — no hunting for links across sketchy sites.

## Requirements

### Validated

- ✓ Kubernetes cluster with ingress, NFS storage, monitoring — existing
- ✓ Cloudflare DNS and TLS — existing
- ✓ CI/CD pipeline (Woodpecker) — existing
- ✓ Terraform/Terragrunt deployment pattern — existing

### Active

- [ ] Auto-scrape configured streaming sites for live F1 stream links
- [ ] Custom per-site extractors to bypass obfuscation (CSRF tokens, JS rendering, redirect chains) and extract final video source URLs
- [ ] Stream health checks — verify extracted streams are actually live and working before displaying
- [ ] Stream proxying/relay through the service for unified playback
- [ ] Auto-pull F1 race schedule from official data (Ergast/OpenF1 API)
- [ ] Cover all F1 sessions: FP1-3, Qualifying, Sprint, Race, pre/post shows, press conferences
- [ ] Svelte web app with schedule view, stream picker, and embedded video player
- [ ] Deploy as a service on the existing K8s cluster

### Out of Scope

- User authentication — security by obscurity (private URL, not publicly discoverable)
- Community features (chat, comments, voting) — just streams
- DVR/recording — live viewing only
- Mobile app — web-only
- Official F1TV integration — unofficial re-streams only

## Context

- Stream sites have anti-scraping protections: CSRF tokens, JavaScript-rendered pages, obfuscated video URLs, redirect chains
- Custom extractors per site are preferred over headless browser for efficiency and reliability
- User will provide the specific sites to scrape — not a discovery/search problem
- F1 calendar data available via Ergast API (ergast.com/mrd/) and OpenF1 API
- HLS (m3u8) is the most common stream format on these sites
- Existing infra supports Svelte apps (user's preferred frontend framework)

## Constraints

- **Frontend**: Svelte — user preference for all new web apps
- **Deployment**: K8s cluster via Terraform/Terragrunt stack pattern
- **Storage**: NFS at 10.0.10.15 for any persistent data
- **No auth**: Rely on non-discoverable URL, no Authentik integration needed
- **Extractors**: Custom per-site logic, no headless browser dependency

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Custom per-site extractors over headless browser | More efficient, reliable, and lighter on resources | — Pending |
| No authentication | Private community, security by obscurity sufficient | — Pending |
| Proxy streams through service | Unified player experience, hides source from end users | — Pending |
| All sessions coverage | Users want full weekend + extras, not just race day | — Pending |

---
*Last updated: 2026-02-23 after initialization*
