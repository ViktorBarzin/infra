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
| goldmane | Calico 3.30 OSS flow aggregator (`goldmane.calico-system.svc:7443`, gRPC/mTLS). Stamps identity (ns/pod/workload/labels + allow-deny) on every flow from Felix into a ~60-min in-memory ring buffer — no etcd/API writes. East-west "who-talks-to-whom" source (ADR-0014). Enabled via operator CR (`kubectl_manifest.goldmane`). | calico |
| whisker | Calico 3.30 OSS live flow-observability UI (`whisker.calico-system.svc:8081`) at `whisker.viktorbarzin.me` (Authentik-gated, `auth=required` — no own login; additive NP ORs Traefik past the operator default-deny). ~60-min live view of Goldmane flows, NOT history. Enabled via operator CR (`kubectl_manifest.whisker`). | calico |
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
| k8s-dashboard | Kubernetes dashboard at `k8s.viktorbarzin.me`. **Forward-auth + auto-injected SA token** (apiserver OIDC blocked, see design §12). nginx token-injector (`dashboard_injector.tf`) maps `X-authentik-username` → the user's `dashboard-<user>` SA token (ns admin + read-only on namespace-list/nodes only via `dashboard-nav-readonly` — no cross-tenant reads, `rbac/.../dashboard-sa.tf`; admins → cluster-admin SA) and sets `Authorization: Bearer` → no token-paste, dashboard auto-authenticates per user. Forward-auth admits `kubernetes-*` groups for this host (`stacks/authentik/admin-services-restriction.tf`). oauth2-proxy + `k8s-dashboard` OIDC app built but idle. | k8s-dashboard |
| reverse-proxy | Generic reverse proxy | reverse-proxy |
| t3code | Multi-user coding-agent GUI at t3.viktorbarzin.me. `auth=required` (Authentik) → DevVM `t3-dispatch` service (`10.0.10.10:3780`, unprivileged user) maps `X-authentik-username` → that user's own `t3-serve@<u>` instance (file perms enforced by uid; wizard→:3773, emo→:3774; unmapped→403) and **auto-injects the t3 session on first visit** (mints via the root `t3-mint` wrapper, scoped sudoers → `/api/auth/bootstrap` `t3_session` cookie). **Source of truth = `infra/scripts/workstation/roster.yaml`** (os_user → authentik_user/k8s_user/tier/namespaces); `roster_engine.py` (pytest-covered) derives desired state and `t3-provision-users` (hourly systemd timer) applies it — constrained accounts, additive per-tier groups, `t3-serve@<u>` instances, and **regenerating** `/etc/ttyd-user-map` + `dispatch.json` (those two are now GENERATED — do not hand-edit). New non-admins inherit wizard's Claude config (machine-wide managed `claudeMd` in `/etc/claude-code/managed-settings.json` + per-user `~/.claude/{skills,rules}` symlinks seeded by `/etc/skel`) and get a **writable git-crypt-LOCKED** infra clone at `~/code` (code plaintext, secret files ciphertext). Tiers: admin / power-user (cluster-wide read-only) / namespace-owner. **Add a user:** one entry in `roster.yaml` → reconcile. Per-user OIDC kubeconfig, the `oidc-power-user-readonly` ClusterRole, and the Authentik `T3 Users` edge gate are applied (the gate is live — only `T3 Users` members reach t3); the emo cutover to his own locked clone is the remaining gated step. DevVM artifacts versioned in `infra/scripts/` (`t3-serve@.service`, `t3-provision-users` + `workstation/{roster.yaml,roster_engine.py,setup-devvm.sh,managed-settings.json,skel/}`, `t3-dispatch/`, `t3-mint`, `sudoers-t3-autopair`, `t3-autoupdate.*`, `t3-safe-restart.sh`, `t3-migrate-idle.*`); TF (`stacks/t3code`) owns only the ingress + Endpoints→:3780. **t3 AUTO-TRACKS the `nightly` npm dist-tag** (Viktor 2026-06-16, reversing the post-2026-06-09 pin; churn risk accepted) — `t3-autoupdate` is a daily GATED tracker that follows `t3@nightly` but gates every bump so a bad build self-heals: downgrade-guard → pre-bump `VACUUM INTO` backup → health-check that SEEDS a copy of a real POPULATED `state.sqlite` to exercise the forward migration + the real mint→exchange→`t3_session` pairing handshake → canary-restart idle instances ONE AT A TIME with per-instance dispatch pairing verify → auto-rollback to last-good + self-freeze on failure (active-agent instances deferred, never killed; last-good in `/var/lib/t3-autoupdate/last-good`). **Deferred instances are drained overnight by `t3-migrate-idle.timer`** (every 20 min 01:00–05:40): it restarts a still-stale `t3-serve@<u>` onto the current binary only when that user's `state.sqlite` shows no in-flight turn (`active_turn_id`) + ≥15 min quiet (`T3_MIGRATE_QUIET_SECONDS`), via the shared `t3-safe-restart.sh` (the same backup→restart→verify→recover helper the canary uses) — fixing the chronic skew where a user busy at every 04:00 window never migrated and saw "Client and server versions differ". The 2026-06-09 outage was the SAME nightly channel WITHOUT these gates. Freeze/revert now: `sudo touch /etc/t3-autoupdate.freeze` (or set `T3_PIN=<ver>` to hard-pin); preview a build with `T3_DRY_RUN=1`. Channel via `T3_TRACK` in `t3-autoupdate.sh` + `setup-devvm.sh` (keep in sync). Full ops + manual rollback: `docs/runbooks/t3-version-bump.md`. `t3-dispatch` is **version-agnostic** (2026-06-09): `autoPair` tries `/api/auth/browser-session` (0.0.25) then falls back to `/api/auth/bootstrap` (0.0.24), so 0.0.24↔0.0.25 needs no dispatch change. `~/.t3` is backed up daily by `t3-backup-state` (online `VACUUM INTO`; previously unbacked — it's the only copy). Native app/app.t3.codes unsupported (cross-origin) — deferred until published. **PWA install layer (2026-07-10):** dispatch serves `/manifest.webmanifest` itself and injects the manifest link (with `crossorigin="use-credentials"` — manifest fetches are cookie-less by spec and would otherwise 302→SSO and die as a console CORS error at the forward-auth edge) + `apple-mobile-web-app-*` standalone metas into proxied HTML (`scripts/t3-dispatch/pwa.go`, `ModifyResponse`, text/html-only, skips encoded bodies; no service worker on purpose) — upstream t3 ships no manifest, so this is what makes t3.viktorbarzin.me installable as a home-screen app (iOS Add to Home Screen). Design: `docs/plans/2026-06-01-t3-auto-provision-*`. **Drop attribution (2026-06-10):** `t3-probe` Deployment (same ns) holds differential legs — `cloudflare` (full public path via DoH-pinned DNS), `internal` (Traefik LB only), `t3serve` (devvm:3773 direct) — against dispatch's unauthenticated `/probe` carve-out (walloff-guarded); Prometheus job `t3-probe`, alerts `T3ProbeLegDown`/`T3ProbeDropBurst`, runbook `docs/runbooks/t3-drop-attribution.md`. `t3-serve@` units carry memory containment (`MemoryHigh=12G/MemoryMax=16G/MemorySwapMax=0/OOMPolicy=continue`) so a runaway agent OOMs alone instead of freezing devvm. **Connection logs (2026-06-11):** `t3-dispatch` logs every `/ws` open/close with `dur_ms` + `cause` (`downstream_closed`=client/CF/Traefik hung up → last-mile; `upstream_closed`=t3-serve closed; `graceful`); devvm journald now ships to Loki via `scripts/devvm-promtail.*` (`{job="devvm-journal"}` + `{job="sshd-devvm"}`), joining Traefik `/ws`-duration + cloudflared close events already in Loki for full per-drop attribution without a repro. **Empirical (2026-06-11):** direct-to-t3-serve held one WS 40 min (0 drops) while a real tunnel session cycled 5×/90s → drop originates above t3-serve on the public path, NOT in t3-serve itself; `t3 auth pairing create`+`/api/auth/browser-session` works, and dispatch **auto-pair was re-verified healthy on the live pin 2026-06-16** (cookieless `X-authentik-username` → 302 + `t3_session`) — the earlier transient 401 note no longer reproduces, and the new dispatch pairing logs + `T3PairingBroken`/`T3PairFallbackHigh` Loki alerts now watch pairing continuously. | t3code |

## Active Use
| Service | Description | Stack |
|---------|-------------|-------|
| goldmane-edge-aggregator | Durable who-talks-to-whom audit trail (ADR-0014 / #58). Go service: `aggregate` Deployment streams Goldmane's gRPC `Flows.Stream` (mTLS) and upserts the low-cardinality namespace-pair edge set (`edge(src_ns,dst_ns,action,first_seen,last_seen,flow_count)`) into CNPG DB `goldmane_edges`; `goldmane-edges-digest` CronJob posts first-seen edges daily to `#alerts` (the `#security` channel was abandoned 2026-06-25 — shared webhook's app isn't a member of it). mTLS client cert REUSES the operator's `whisker-backend-key-pair` (re-apply if rotated). Tier-4-aux. Image `ghcr.io/viktorbarzin/goldmane-edge-aggregator` (private). Runbook: [goldmane-flow-trail.md](../../docs/runbooks/goldmane-flow-trail.md). | goldmane-edge-aggregator |
| mailserver | Email (docker-mailserver) | mailserver |
| shadowsocks | Proxy | shadowsocks |
| webhook_handler | Webhook processing | webhook_handler |
| tuya-bridge | Smart home bridge | tuya-bridge |
| android-emulator | Shared Android 16 test emulator (adb 10.0.20.200:5555, noVNC android-emulator.viktorbarzin.lan) | android-emulator |
| anisette | Self-hosted Apple anisette-data server (Dadoum/anisette-v3-server, digest-pinned) for sideloading the TripIt iOS Shell via SideStore; internal-only http://anisette.viktorbarzin.lan, auth=none, LAN-only, stateless | anisette |
| dawarich | Location history | dawarich |
| owntracks | Location tracking | owntracks |
| nextcloud | File sync/share | nextcloud |
| calibre | E-book management (may be merged into ebooks stack) | calibre |
| f1-stream | F1 streaming (uses chrome-service for hmembeds verifier); canonical source in own repo `viktor/f1-stream` (Forgejo, extracted 2026-06-05); GHA-built → `ghcr.io/viktorbarzin/f1-stream` (private), Woodpecker deploy-only (ADR-0002) | f1-stream |
| chrome-service | Headed Chromium over CDP (`http://chrome-service.chrome-service.svc:9222`, `connect_over_cdp`; legacy `:3000/<token>` WS pool removed 2026-06-04) for sibling services driving anti-bot pages — snapshot-harvester CronJob + tripit fare scrape | chrome-service |
| rybbit | Analytics | rybbit |
| isponsorblocktv | SponsorBlock for TV | isponsorblocktv |
| actualbudget | Budgeting (factory pattern) | actualbudget |
| insta2spotify | Instagram reel song ID to Spotify playlist | insta2spotify |
| trading-bot | Event-driven trading with sentiment analysis | trading-bot |
| claude-memory | Persistent memory MCP server | claude-memory |
| paperless-mcp | Paperless-ngx document search MCP (barryw/PaperlessMCP). Traefik bearer auth via Aetherinox api-token-middleware. `auth=none` at ingress; gateway-level bearer enforced by `paperless-mcp/bearer-auth` Middleware CRD. Tokens + paperless API token in Vault `secret/paperless-mcp`. | paperless-mcp |
| learn | learn Viewer — Authentik-gated web surface for /teach learning workspaces at `learn.viktorbarzin.me`. Cluster-native since 2026-07-09 (v1 served live off the DevVM — superseded, monorepo `learn/docs/adr/0002`): Caddy container + git-sync sidecar (30s poll, SSH deploy key `learn-viewer git-sync`, Vault `secret/learn` → ES `learn-git-creds`) serving the GitHub monorepo's `learn/` at git HEAD — lessons appear on PUSH (~30-60s; the teach skill auto-pushes). OWNER-ONLY: Caddy serves only `X-Authentik-Username` ^vbarzin(@.*)?$, else 403. `auth=required`. **Same pod also serves `plans.viktorbarzin.me`** (since 2026-07-10, infra#72): the monorepo's `plans/` tree — HTML plan snapshots rendered by the publish-plan skill; Caddyfile splits sites by Host, identical owner-only gate, second ingress `module.ingress_plans`. | learn |
| paperless-ai | AI layer over Paperless-ngx (clusterzx/paperless-ai): semantic/RAG document search (Chat) + auto-tagging. Local embeddings (sentence-transformers MiniLM) + ChromaDB on the PVC — search is GPU-free. LLM (chat answers + tagging) via in-cluster llama-swap `qwen3-8b` (`SYSTEM_PROMPT=/no_think` to keep Qwen3 output parseable). `auth=required` (Authentik) at `paperless-ai.viktorbarzin.me`. Reads Paperless over the internal svc as a dedicated `paperless-ai` superuser. **Runtime config + app-admin live in the PVC `.env`/SQLite (written once via the app's setup flow), NOT TF env — its dotenv loader does not override `process.env`, so container env shadows the `.env`.** Vault `secret/paperless-ai` (paperless_api_token, api_key, custom_api_key, app_admin_*). | paperless-ai |

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
| paperless-ngx | Document management. Mail ingest: forward document emails to `docs@viktorbarzin.me` — sender maps 1:1 to a paperless account (runbook `paperless-mail-ingest.md`) | paperless-ngx |
| jsoncrack | JSON visualizer | jsoncrack |
| servarr | Media automation (Sonarr/Radarr/etc) | servarr |
| aiostreams | Stremio stream aggregator (Real-Debrid + Torrentio/Comet/StremThru Torz/Knaben; **MediaFusion removed 2026-06-07** — broken upstream `500`). `auth=app` (own UUID+password); stream-probe tests **both series+movie paths** with per-source breakdown (`aiostreams_streams_{comet,torrentio,stremthru_torz,knaben}`) + `aiostreams_error_streams` + `aiostreams_movie_stream_count`, success gated on Comet (workhorse) being alive; weekly NFS config + Stremio-account-collection backups to `/srv/nfs/aiostreams-backup/`. PG-backed user config (Comet timeout bumped 5s→10s 2026-06-07). | servarr/aiostreams |
| ntfy | Push notifications | ntfy |
| cyberchef | Data transformation | cyberchef |
| diun | Docker image update notifier — detects new versions, fires webhook to n8n upgrade agent | diun |
| meshcentral | Remote management | meshcentral |
| homepage | Dashboard/startpage | homepage |
| matrix | Matrix homeserver (tuwunel — Rust, RocksDB; native password auth) | matrix |
| linkwarden | Bookmark manager | linkwarden |
| changedetection | Web change detection | changedetection |
| tandoor | Recipe manager | tandoor |
| n8n | Workflow automation | n8n |
| real-estate-crawler | Property crawler | real-estate-crawler |
| tor-proxy | Tor proxy | tor-proxy |
| forgejo | Git forge. Open native self-signup (Turnstile captcha + email confirm) + Authentik & GitHub OAuth sign-in; see `docs/runbooks/forgejo-open-signups.md` | forgejo |
| freshrss | RSS reader | freshrss |
| drone-logbook | DJI flight-log analyzer (Open DroneLog, upstream image) — dronelog.viktorbarzin.me | drone-logbook |
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
| tripit | Self-hosted TripIt-clone travel-itinerary PWA (FastAPI + SvelteKit SPA, same-origin). CNPG (`tripit` db, Vault static role `pg-tripit`) + RWX NFS trip-doc vault (`/srv/nfs/tripit-documents`) + RWO `proxmox-lvm-encrypted` personal-document vault `tripit-personal-documents` (passports/IDs — AES-256-GCM app-layer envelope, master key `DOCUMENT_ENCRYPTION_KEY` in `secret/tripit`). `auth=required` (Authentik forward-auth, reads `X-authentik-email`); second `auth=none` ingress on `/api/calendar` for HMAC-token-gated `.ics` feed. Email-ingest CronJob `tripit-ingest-plans` (`*/15`) is the SOLE inbound path — forward a booking to plans@viktorbarzin.me (catch-all → spam@), polled read-only and routed ONLY to a registered user / verified linked address (no default-owner fallback; strangers ignored), parsed by local LLM (`qwen3vl-4b`), and the sender is emailed the outcome (Added to trip / Couldn't import). Plus `tripit-poll-flights`, `tripit-run-reminders`, `tripit-transport-nudge`, `tripit-weather-brief`. (The old Gmail-scrape `tripit-ingest-mail` CronJob was removed 2026-06-05.) App secrets in Vault `secret/tripit`. | tripit |
| tasks | Reminders-style tasks PWA over Nextcloud CalDAV (FastAPI + SvelteKit SPA same-origin, single container; code `~/code/tasks`, design `tasks/docs/2026-07-03-tasks-pwa-design.md`). Nextcloud stays the source of truth (VTODOs); the app is the front-end Apple Reminders stopped being. CNPG (`tasks` db, Vault static role `pg-tasks`) stores Connected Accounts — per-user Nextcloud app passwords Fernet-encrypted with `fernet_key` from `secret/tasks`. `auth=required` (Authentik forward-auth; identity = `X-authentik-username`, NO app-level login — `DEV_USER` must never be set in prod) at tasks.viktorbarzin.me (proxied). Exception: the five PWA icon/manifest files (`/apple-touch-icon.png`, `/favicon.png`, `/pwa-192x192.png`, `/pwa-512x512.png`, `/manifest.webmanifest`) are a path-scoped `auth=none` carve-out (`module.ingress_icons`) so cookie-less OS icon fetchers (macOS Safari Add-to-Dock, mobile home-screen installs) get the real icon instead of the Authentik 302; guarded by the `tasks-icons` walloff-probe target. NetworkPolicy `tasks-ingress` (SEC-1) restricts pod ingress to traefik + monitoring namespaces so the trusted header can't be spoofed pod-to-pod. GHA → public ghcr `tasks` → Woodpecker deploy (ADR-0002). | tasks |
| stem95su | STEM educational platform for **95. СУ „Проф. Иван Шишманов"** (Sofia school) at stem95su.viktorbarzin.me — **a Valia site on Cloudflare Pages since 2026-07-03** (ADR-0018): registry entry in `stacks/valia-sites`, synced from Drive folder "claude" every 10 min, deploy-on-change. The old in-cluster stack (nginx off PVE NFS + per-site rclone CronJob) is RETIRED — stacks/stem95su is a tombstone; `secret/stem95su` superseded by `secret/valia-sites`; `stem_video.mp4` was compressed 42.9→21.4MB (25MB Pages cap) with Viktor's OK. See docs/runbooks/valia-sites.md. | — |
| valia-sites | **Valia-site registry + sync** (ADR-0018): all sites authored by Valia serve OFF-INFRA on Cloudflare Pages (`bridge` + `stem95su` live). One map entry in `stacks/valia-sites/main.tf` per site fans out Pages project + custom domain + public CNAME + internal split-horizon CNAME (ConfigMap `valia-sites-dns` → technitium sync, declarative incl. removal). CronJob `valia-sites-sync` (`*/10`, image ghcr `valia-sites-sync`) mirrors each Drive Content folder (rclone `drive.readonly`, stem95su-style guards + 25MB Pages-cap guard) and wrangler-deploys ONLY on manifest change (free-tier deploy cap). Secrets `secret/valia-sites` (shared rclone conf + SCOPED CF Pages token — Global API Key never in pods). Failed-Job-only visibility by choice. Runbook: docs/runbooks/valia-sites.md. | valia-sites |
| trek | **TRIAL (2026-06-05)** — self-hosted group-trip planner (upstream [TREK](https://github.com/mauriceboe/TREK), `mauriceboe/trek:3.0.22`, AGPL-3.0). Solo evaluation behind Authentik forward-auth (`auth=required`) before deciding build-vs-adopt; covers collaborative trip planning + accommodation records + activities + per-person budget splitting on free OpenStreetMap (no paid maps key). SQLite + uploads on `proxmox-lvm-encrypted` (`trek-data-encrypted` 2Gi, `trek-uploads-encrypted` 5Gi). For the trial only: `ENCRYPTION_KEY` is TREK-auto-generated onto the data PVC and the bootstrap admin (`admin@trek.local`) is printed to pod logs — NO Vault/ESO wiring (graduation TODO: move key to `secret/trek` + ESO, add an app-level SQLite backup CronJob since host file-backup can't read the LUKS PVC, wire TREK↔Authentik OIDC). Pinned image, TF-managed (no CI/Keel). Availability-poll companion (Rallly) deferred. Teardown: `tg destroy` in `stacks/trek`. | trek |

## Cloudflare Domains

### Proxied (CDN + WAF enabled)
```
blog, hackmd, privatebin, url, echo, f1tv, excalidraw, send,
audiobookshelf, jsoncrack, ntfy, cyberchef, homepage, linkwarden,
changedetection, tandoor, n8n, stirling-pdf, dashy, city-guesser,
travel, netbox, phpipam, tripit, t3, stem95su, tasks
```

### Non-Proxied (Direct DNS)
```
mail, wg, headscale, immich, calibre, vaultwarden,
mailserver-antispam, mailserver-admin, webhook, uptime,
owntracks, dawarich, tuya, meshcentral, nextcloud, actualbudget,
forgejo, freshrss, navidrome, ollama, openwebui,
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
| Goldmane flow trail (east-west who-talks-to-whom) | [goldmane-flow-trail.md](../../docs/runbooks/goldmane-flow-trail.md) |
