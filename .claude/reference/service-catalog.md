# Service Catalog

> Auto-maintained reference. See `.claude/CLAUDE.md` for operational guidance.

## Critical - Network & Auth (Tier: core)
| Service | Description | Stack |
|---------|-------------|-------|
| wireguard | VPN server | wireguard |
| technitium | DNS server (10.0.20.201, query logging on PostgreSQL via custom PG plugin) | technitium |
| headscale | Tailscale control server | headscale |
| traefik | Ingress controller (Helm) | traefik |
| xray | Proxy/tunnel | platform |
| authentik | Identity provider (SSO) | authentik |
| cloudflared | Cloudflare tunnel | cloudflared |
| authelia | Auth middleware (may be merged into ebooks or removed) | platform |
| monitoring | Prometheus/Grafana/Loki stack | monitoring |

## Storage & Security (Tier: cluster)
| Service | Description | Stack |
|---------|-------------|-------|
| vaultwarden | Bitwarden-compatible password manager | platform |
| redis | Shared Redis at `redis.redis.svc.cluster.local` | redis |
| immich | Photo management (GPU) | immich |
| nvidia | GPU device plugin | nvidia |
| metrics-server | K8s metrics | metrics-server |
| uptime-kuma | Status monitoring | uptime-kuma |
| crowdsec | Security/WAF (PostgreSQL backend) | crowdsec |
| kyverno | Policy engine | kyverno |

## Admin
| Service | Description | Stack |
|---------|-------------|-------|
| k8s-dashboard | Kubernetes dashboard | k8s-dashboard |
| reverse-proxy | Generic reverse proxy | reverse-proxy |

## Active Use
| Service | Description | Stack |
|---------|-------------|-------|
| mailserver | Email (docker-mailserver) | mailserver |
| shadowsocks | Proxy | shadowsocks |
| webhook_handler | Webhook processing | webhook_handler |
| tuya-bridge | Smart home bridge | tuya-bridge |
| dawarich | Location history | dawarich |
| owntracks | Location tracking | owntracks |
| nextcloud | File sync/share | nextcloud |
| calibre | E-book management (may be merged into ebooks stack) | calibre |
| onlyoffice | Document editing | onlyoffice |
| f1-stream | F1 streaming | f1-stream |
| rybbit | Analytics | rybbit |
| isponsorblocktv | SponsorBlock for TV | isponsorblocktv |
| actualbudget | Budgeting (factory pattern) | actualbudget |
| insta2spotify | Instagram reel song ID to Spotify playlist | insta2spotify |
| trading-bot | Event-driven trading with sentiment analysis | trading-bot |
| claude-memory | Persistent memory MCP server | claude-memory |
| council-complaints | Islington civic reporting pilot | council-complaints |

## Optional
| Service | Description | Stack |
|---------|-------------|-------|
| blog | Personal blog | blog |
| descheduler | Pod descheduler | descheduler |
| hackmd | Collaborative markdown | hackmd |
| kms | Key management | kms |
| privatebin | Encrypted pastebin | privatebin |
| vault | HashiCorp Vault | vault |
| reloader | ConfigMap/Secret reloader | reloader |
| city-guesser | Game | city-guesser |
| echo | Echo server | echo |
| url | URL shortener | url |
| excalidraw | Whiteboard | excalidraw |
| travel_blog | Travel blog | travel_blog |
| dashy | Dashboard | dashy |
| send | Firefox Send | send |
| ytdlp | YouTube downloader | ytdlp |
| wealthfolio | Finance tracking | wealthfolio |
| audiobookshelf | Audiobook server (may be merged into ebooks stack) | audiobookshelf |
| paperless-ngx | Document management | paperless-ngx |
| jsoncrack | JSON visualizer | jsoncrack |
| servarr | Media automation (Sonarr/Radarr/etc) | servarr |
| ntfy | Push notifications | ntfy |
| cyberchef | Data transformation | cyberchef |
| diun | Docker image update notifier | diun |
| meshcentral | Remote management | meshcentral |
| homepage | Dashboard/startpage | homepage |
| matrix | Matrix chat server | matrix |
| linkwarden | Bookmark manager | linkwarden |
| changedetection | Web change detection | changedetection |
| tandoor | Recipe manager | tandoor |
| n8n | Workflow automation | n8n |
| real-estate-crawler | Property crawler | real-estate-crawler |
| tor-proxy | Tor proxy | tor-proxy |
| forgejo | Git forge | forgejo |
| freshrss | RSS reader | freshrss |
| navidrome | Music streaming | navidrome |
| networking-toolbox | Network tools | networking-toolbox |
| stirling-pdf | PDF tools | stirling-pdf |
| speedtest | Speed testing | speedtest |
| freedify | Music streaming (factory pattern) | freedify |
| phpipam | IP Address Management (IPAM) + auto-discovery | phpipam |
| ~~netbox~~ | ~~Network documentation~~ (disabled, replaced by phpipam) | netbox |
| infra-maintenance | Maintenance jobs | infra-maintenance |
| ollama | LLM server (GPU) | ollama |
| frigate | NVR/camera (GPU) | frigate |
| ebook2audiobook | E-book to audio (GPU) | ebook2audiobook |
| affine | Visual canvas/whiteboard (PostgreSQL + Redis) | affine |
| health | Apple Health data dashboard (PostgreSQL) | health |
| whisper | Wyoming Faster Whisper STT (CPU on GPU node) | whisper |
| grampsweb | Genealogy web app (Gramps Web) | grampsweb |
| openclaw | AI agent gateway (OpenClaw) | openclaw |
| poison-fountain | Anti-AI scraping (tarpit + poison) | poison-fountain |
| priority-pass | Boarding pass color transformer | priority-pass |
| status-page | Status page | status-page |
| plotting-book | Book plotting/world-building app | plotting-book |

## Cloudflare Domains

### Proxied (CDN + WAF enabled)
```
blog, hackmd, privatebin, url, echo, f1tv, excalidraw, send,
audiobookshelf, jsoncrack, ntfy, cyberchef, homepage, linkwarden,
changedetection, tandoor, n8n, stirling-pdf, dashy, city-guesser,
travel, netbox, phpipam
```

### Non-Proxied (Direct DNS)
```
mail, wg, headscale, immich, calibre, vaultwarden,
mailserver-antispam, mailserver-admin, webhook, uptime,
owntracks, dawarich, tuya, meshcentral, nextcloud, actualbudget,
onlyoffice, forgejo, freshrss, navidrome, ollama, openwebui,
isponsorblocktv, speedtest, freedify, rybbit, paperless,
servarr, prowlarr, bazarr, radarr, sonarr, flaresolverr,
jellyfin, jellyseerr, tdarr, affine, health, family, openclaw
```

### Special Subdomains
- `*.viktor.actualbudget` - Actualbudget factory instances
- `*.freedify` - Freedify factory instances
- `mailserver.*` - Mail server components (antispam, admin)
