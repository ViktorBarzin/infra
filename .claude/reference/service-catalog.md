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
| redis | Shared Redis 8.x via HAProxy at `redis-master.redis.svc.cluster.local` — 3-pod raw StatefulSet `redis-v2` (redis+sentinel+exporter per pod), quorum=2. Clients use HAProxy only, no sentinel fallback. | redis |
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
| t3code | Multi-user coding-agent GUI at t3.viktorbarzin.me. `auth=required` (Authentik) → in-cluster nginx `t3-dispatch` maps `X-authentik-username` → that user's own `t3 serve` on DevVM (vbarzin→:3773 `t3-serve.service`; emil.barzin→:3774 `t3-serve-emo.service`; unmapped→403). Per-user isolation mirroring the `terminal` stack. **Add a user:** create `t3-serve-<u>.service` on DevVM (own `--port`/`--base-dir`, `User=<u>`) + add a line to the dispatch nginx `map` in `stacks/t3code/main.tf` + apply. RCE surface; each user self-pairs via `t3 auth pairing create`. Native app/app.t3.codes unsupported here (cross-origin) — deferred until published. | t3code |

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
| f1-stream | F1 streaming (uses chrome-service for hmembeds verifier) | f1-stream |
| chrome-service | Headed Chromium WebSocket pool (`ws://chrome-service.chrome-service.svc:3000/<token>`) for sibling services driving anti-bot embeds | chrome-service |
| rybbit | Analytics | rybbit |
| isponsorblocktv | SponsorBlock for TV | isponsorblocktv |
| actualbudget | Budgeting (factory pattern) | actualbudget |
| insta2spotify | Instagram reel song ID to Spotify playlist | insta2spotify |
| trading-bot | Event-driven trading with sentiment analysis | trading-bot |
| claude-memory | Persistent memory MCP server | claude-memory |
| paperless-mcp | Paperless-ngx document search MCP (barryw/PaperlessMCP). Traefik bearer auth via Aetherinox api-token-middleware. `auth=none` at ingress; gateway-level bearer enforced by `paperless-mcp/bearer-auth` Middleware CRD. Tokens + paperless API token in Vault `secret/paperless-mcp`. | paperless-mcp |
| council-complaints | Islington civic reporting pilot | council-complaints |

## Optional
| Service | Description | Stack |
|---------|-------------|-------|
| blog | Personal blog | blog |
| descheduler | Pod descheduler | descheduler |
| hackmd | Collaborative markdown | hackmd |
| kms | Windows/Office volume-license activation (vlmcsd); site kms.viktorbarzin.me, endpoint vlmcs.viktorbarzin.me:1688 | kms |
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
| aiostreams | Stremio stream aggregator (Real-Debrid + Torrentio/Comet/MediaFusion/StremThru/Knaben). `auth=app` (own UUID+password); canary stream-probe + 3 alerts; weekly NFS config + Stremio-account-collection backups to `/srv/nfs/aiostreams-backup/`. PG-backed user config. | servarr/aiostreams |
| ntfy | Push notifications | ntfy |
| cyberchef | Data transformation | cyberchef |
| diun | Docker image update notifier — detects new versions, fires webhook to n8n upgrade agent | diun |
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
| tripit | Self-hosted TripIt-clone travel-itinerary PWA (FastAPI + SvelteKit SPA, same-origin). CNPG (`tripit` db, Vault static role `pg-tripit`) + RWX NFS doc vault (`/srv/nfs/tripit-documents`). `auth=required` (Authentik forward-auth, reads `X-authentik-email`); second `auth=none` ingress on `/api/calendar` for HMAC-token-gated `.ics` feed. Email-ingest CronJob `tripit-ingest-mail` (`*/30`) parses me@viktorbarzin.me via read-only IMAP with local LLM (`qwen3vl-4b`); plus `tripit-poll-flights` + `tripit-run-reminders`. App secrets in Vault `secret/tripit`. | tripit |

## Cloudflare Domains

### Proxied (CDN + WAF enabled)
```
blog, hackmd, privatebin, url, echo, f1tv, excalidraw, send,
audiobookshelf, jsoncrack, ntfy, cyberchef, homepage, linkwarden,
changedetection, tandoor, n8n, stirling-pdf, dashy, city-guesser,
travel, netbox, phpipam, tripit, t3
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

## Key Runbooks

Operational surfaces that aren't k8s services (VMs, pipelines, host-side
procedures) are documented in `infra/docs/runbooks/`:

| Surface | Runbook |
|---|---|
| Private Docker registry VM (10.0.20.10) | [registry-vm.md](../../docs/runbooks/registry-vm.md) |
| Rebuild after orphan-index incident | [registry-rebuild-image.md](../../docs/runbooks/registry-rebuild-image.md) |
| PVE host operations (backups, LVM) | [proxmox-host.md](../../docs/runbooks/proxmox-host.md) |
| NFS prerequisites and CSI mount options | [nfs-prerequisites.md](../../docs/runbooks/nfs-prerequisites.md) |
| pfSense + Unbound DNS | [pfsense-unbound.md](../../docs/runbooks/pfsense-unbound.md) |
| Mailserver PROXY-protocol / HAProxy | [mailserver-pfsense-haproxy.md](../../docs/runbooks/mailserver-pfsense-haproxy.md) |
| Technitium apply flow | [technitium-apply.md](../../docs/runbooks/technitium-apply.md) |
