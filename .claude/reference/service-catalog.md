# Service Catalog

> Auto-maintained reference. See `.claude/CLAUDE.md` for operational guidance.

## Critical - Network & Auth (Tier: core)
| Service | Description | Stack |
|---------|-------------|-------|
| wireguard | VPN server | platform |
| technitium | DNS server (10.0.20.101) | platform |
| headscale | Tailscale control server | platform |
| traefik | Ingress controller (Helm) | platform |
| xray | Proxy/tunnel | platform |
| authentik | Identity provider (SSO) | platform |
| cloudflared | Cloudflare tunnel | platform |
| authelia | Auth middleware | platform |
| monitoring | Prometheus/Grafana/Loki stack | platform |

## Storage & Security (Tier: cluster)
| Service | Description | Stack |
|---------|-------------|-------|
| vaultwarden | Bitwarden-compatible password manager | platform |
| redis | Shared Redis at `redis.redis.svc.cluster.local` | platform |
| immich | Photo management (GPU) | immich |
| nvidia | GPU device plugin | platform |
| metrics-server | K8s metrics | platform |
| uptime-kuma | Status monitoring | platform |
| crowdsec | Security/WAF | platform |
| kyverno | Policy engine | platform |

## Admin
| Service | Description | Stack |
|---------|-------------|-------|
| k8s-dashboard | Kubernetes dashboard | platform |
| reverse-proxy | Generic reverse proxy | platform |

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
| calibre | E-book management | calibre |
| onlyoffice | Document editing | onlyoffice |
| f1-stream | F1 streaming | f1-stream |
| rybbit | Analytics | rybbit |
| isponsorblocktv | SponsorBlock for TV | isponsorblocktv |
| actualbudget | Budgeting (factory pattern) | actualbudget |

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
| audiobookshelf | Audiobook server | audiobookshelf |
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
| netbox | Network documentation | netbox |
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

## Cloudflare Domains

### Proxied (CDN + WAF enabled)
```
blog, hackmd, privatebin, url, echo, f1tv, excalidraw, send,
audiobookshelf, jsoncrack, ntfy, cyberchef, homepage, linkwarden,
changedetection, tandoor, n8n, stirling-pdf, dashy, city-guesser,
travel, netbox
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
