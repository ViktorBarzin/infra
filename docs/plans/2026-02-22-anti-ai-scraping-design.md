# Anti-AI Scraping System Design

> **Status (Updated 2026-04-17):** Partially superseded. Layer 3 (trap links via rewrite-body plugin) removed due to Traefik v3.6.12 Yaegi plugin incompatibility. The `strip-accept-encoding` and `anti-ai-trap-links` middlewares have been deleted. Rybbit analytics injection moved from Traefik rewrite-body to a Cloudflare Worker (`infra/stacks/rybbit/worker/`). Active layers: 1 (bot-block), 2 (headers), 4 (tarpit), 5 (poison content).

## Problem

AI scrapers crawl public web services to harvest training data. We want to:
1. Block known AI crawlers outright
2. Poison the data that unknown scrapers collect
3. Waste scraper resources with slow responses and infinite crawl loops

## Architecture

Four active defense layers applied to all public services via Traefik (Layer 3 removed April 2026):

```
Internet -> Cloudflare -> Traefik
                           |
                           +-- Layer 1: ForwardAuth -> block known AI User-Agents (403)
                           |
                           +-- Layer 2: Headers -> X-Robots-Tag: noai, noimageai
                           |
                           +-- [REMOVED] Layer 3: Rewrite-body trap links (April 2026 — Yaegi bugs in Traefik v3.6.12)
                           |
                           +-- Layer 4: Poison service -> serve cached Poison Fountain data
                           |
                           +-- Layer 5: Tarpit -> slow-drip responses + infinite crawl loop
```

## Components

### 1. poison-fountain service (new Kubernetes deployment)

A Python service with three responsibilities:

**ForwardAuth endpoint (`GET /auth`)**:
- Reads `X-Forwarded-For` and `User-Agent` from request headers
- Checks User-Agent against list of known AI bot strings
- Returns 403 for matches, 200 for legitimate users
- Blocked bots: GPTBot, ChatGPT-User, ClaudeBot, Claude-Web, CCBot, Bytespider, Google-Extended, Applebot-Extended, anthropic-ai, cohere-ai, Diffbot, FacebookBot, PerplexityBot, YouBot, Meta-ExternalAgent, PetalBot, Amazonbot, AI2Bot, Omgilibot, img2dataset

**Poison content endpoint (`GET /article/<slug>`)**:
- Serves cached poisoned content from NFS
- Wraps raw Poison Fountain data in realistic HTML templates (title, headings, paragraphs)
- Each response includes 10+ links to other poison pages (infinite crawl loop)
- Uses chunked transfer encoding to drip-feed content at ~100 bytes/second (tarpit)
- Response size: 50-100KB per page

**Health endpoint (`GET /healthz`)**:
- Returns 200 OK for Kubernetes probes

### 2. poison-fountain-fetcher CronJob

- Runs every 6 hours
- Fetches gzip content from `https://rnsaffn.com/poison2/`
- Decompresses and stores to NFS at `/mnt/main/poison-fountain/cache/`
- Maintains a pool of ~50 cached poison documents
- Falls back to locally generated Markov-chain nonsense if Poison Fountain is unreachable

### 3. Traefik middleware additions

All defined in `stacks/platform/modules/traefik/middleware.tf`:

**`ai-bot-block` (ForwardAuth)**:
- ForwardAuth to `http://poison-fountain.poison-fountain.svc.cluster.local:8080/auth`
- Trust forwarded headers from Traefik
- Added to all public services via ingress_factory

**`anti-ai-headers` (Headers)**:
- Sets `X-Robots-Tag: noai, noimageai` on all responses
- Added to all public services via ingress_factory

**`anti-ai-trap-links` (rewrite-body plugin)** — REMOVED (Updated 2026-04-17):
- Removed due to Traefik v3.6.12 Yaegi runtime bugs making the rewrite-body plugin unreliable
- The companion `strip-accept-encoding` middleware was also removed (only existed for rewrite-body)
- Trap link injection is no longer active; poison-fountain still serves tarpit content standalone

### 4. Trap subdomain: poison.viktorbarzin.me

- Cloudflare DNS record (non-proxied, direct to cluster)
- IngressRoute routing all paths to poison-fountain service
- NO rate limiting on this route (let scrapers consume all they want)
- NO CrowdSec on this route (don't block scrapers here)
- Serves poisoned content with tarpit slow-drip

### 5. ingress_factory changes

New variables:
- `anti_ai_scraping` (bool, default: true) - enable all anti-AI layers
- When true, adds to middleware chain: `ai-bot-block`, `anti-ai-headers`
- Services can opt out with `anti_ai_scraping = false`

## Human User Protection

| Concern | Protection |
|---------|-----------|
| Hidden links visible | CSS `position:absolute;left:-9999px;height:0;overflow:hidden` + `aria-hidden="true"` |
| False positive blocking | Only blocks specific AI bot User-Agent strings; no browser matches these |
| Performance overhead | ForwardAuth is a string match (<1ms). Rybbit injected via Cloudflare Worker (not Traefik). |
| Poison content leakage | Only served on poison.viktorbarzin.me, not linked from any navigation |
| Slow responses | Tarpit only applies to poison.viktorbarzin.me, not to real services |

## File Locations

| Component | Path |
|-----------|------|
| Poison service stack | `stacks/poison-fountain/main.tf` |
| Poison service code | `stacks/poison-fountain/app/` |
| Middleware definitions | `stacks/platform/modules/traefik/middleware.tf` |
| ingress_factory changes | `modules/kubernetes/ingress_factory/main.tf` |
| Cloudflare DNS | `terraform.tfvars` (cloudflare_non_proxied_names) |
| NFS cache | `/mnt/main/poison-fountain/cache/` |

## Deployment Order

1. Add Cloudflare DNS record for `poison.viktorbarzin.me`
2. Create NFS export for `/mnt/main/poison-fountain`
3. Add Traefik middlewares (ai-bot-block, anti-ai-headers, anti-ai-trap-links)
4. Update ingress_factory with anti_ai_scraping variable
5. Deploy poison-fountain service + CronJob
6. Apply platform stack (Traefik + Cloudflare changes)
7. Apply poison-fountain stack
8. Apply all other stacks to pick up new ingress_factory defaults
