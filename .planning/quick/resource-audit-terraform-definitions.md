# Terraform Container Resource Audit

Generated: 2026-03-01

## Tier Defaults (Kyverno LimitRange)

For reference, containers WITHOUT explicit `resources {}` blocks receive these defaults from Kyverno-generated LimitRanges:

| Tier | Default CPU | Default Mem | Request CPU | Request Mem | Max CPU | Max Mem |
|------|-------------|-------------|-------------|-------------|---------|---------|
| 0-core | 500m | 512Mi | 50m | 64Mi | 4 | 8Gi |
| 1-cluster | 500m | 512Mi | 50m | 64Mi | 2 | 4Gi |
| 2-gpu | 1 | 2Gi | 100m | 256Mi | 8 | 16Gi |
| 3-edge | 250m | 256Mi | 25m | 64Mi | 2 | 4Gi |
| 4-aux | 250m | 256Mi | 25m | 64Mi | 2 | 4Gi |

Namespaces with custom LimitRange (opt-out): `nextcloud`, `onlyoffice`

---

## Section 1: Containers WITHOUT Explicit Resources (Relying on LimitRange Defaults)

These are the highest-risk containers -- they receive LimitRange defaults which may be too low or too high.

| Stack | Namespace | Deployment/Resource | Container | Tier | Default CPU Lim | Default Mem Lim | Risk Notes |
|-------|-----------|-------------------|-----------|------|-----------------|-----------------|------------|
| blog | website | blog | nginx-exporter | 4-aux | 250m | 256Mi | Sidecar; likely fine |
| cyberchef | cyberchef | cyberchef | cyberchef | 4-aux | 250m | 256Mi | |
| echo | echo | echo | echo | 3-edge | 250m | 256Mi | 5 replicas, no resources |
| networking-toolbox | networking-toolbox | networking-toolbox | networking-toolbox | 4-aux | 250m | 256Mi | 3 replicas |
| shadowsocks | shadowsocks | shadowsocks | shadowsocks | 3-edge | 250m | 256Mi | |
| tor-proxy | tor-proxy | tor-proxy | tor-proxy | 4-aux | 250m | 256Mi | |
| tuya-bridge | tuya-bridge | tuya-bridge | tuya-bridge | 1-cluster | 500m | 512Mi | 3 replicas in cluster tier |
| audiobookshelf | audiobookshelf | audiobookshelf | audiobookshelf | 4-aux | 250m | 256Mi | May need more for transcoding |
| changedetection | changedetection | changedetection | sockpuppetbrowser | 4-aux | 250m | 256Mi | Chromium browser; likely needs more |
| changedetection | changedetection | changedetection | changedetection | 4-aux | 250m | 256Mi | |
| diun | diun | diun | diun | 4-aux | 250m | 256Mi | |
| excalidraw | excalidraw | excalidraw | excalidraw | 4-aux | 250m | 256Mi | |
| freshrss | freshrss | freshrss | freshrss | 4-aux | 250m | 256Mi | |
| isponsorblocktv | isponsorblocktv | isponsorblocktv-vermont | isponsorblocktv-vermont | 3-edge | 250m | 256Mi | |
| matrix | matrix | matrix | matrix | 4-aux | 250m | 256Mi | 0 replicas (disabled) |
| navidrome | navidrome | navidrome | navidrome | 4-aux | 250m | 256Mi | Music streaming |
| ntfy | ntfy | ntfy | ntfy | 4-aux | 250m | 256Mi | |
| owntracks | owntracks | owntracks | owntracks | 4-aux | 250m | 256Mi | |
| privatebin | privatebin | privatebin | privatebin | 3-edge | 250m | 256Mi | |
| wealthfolio | wealthfolio | wealthfolio | wealthfolio | 4-aux | 250m | 256Mi | |
| whisper | whisper | whisper | whisper | 2-gpu | 1 | 2Gi | No GPU resource claim; GPU tier |
| whisper | whisper | piper | piper | 2-gpu | 1 | 2Gi | No GPU resource claim; GPU tier |
| send | send | send | send | 4-aux | 250m | 256Mi | |
| n8n | n8n | n8n | n8n | 4-aux | 250m | 256Mi | Workflow automation; may need more |
| linkwarden | linkwarden | linkwarden | linkwarden | 4-aux | 250m | 256Mi | Next.js app; may OOM |
| dawarich | dawarich | dawarich | dawarich | 3-edge | 250m | 256Mi | Rails app; may OOM |
| hackmd | hackmd | hackmd | codimd | 3-edge | 250m | 256Mi | Node.js; may need more |
| tandoor | tandoor | tandoor | recipes | 4-aux | 250m | 256Mi | Django app |
| grampsweb | grampsweb | grampsweb | grampsweb | 4-aux | 250m | 256Mi | Flask app |
| grampsweb | grampsweb | grampsweb | grampsweb-celery | 4-aux | 250m | 256Mi | Celery worker |
| affine | affine | affine | migration (init) | 4-aux | 250m | 256Mi | Init container; runs prisma migrate |
| actualbudget (factory) | actualbudget | actualbudget-{name} | actualbudget | 3-edge | 250m | 256Mi | 3 instances (viktor, anca, emo) |
| actualbudget (factory) | actualbudget | actualbudget-http-api-{name} | actualbudget | 3-edge | 250m | 256Mi | Conditional (budget_encryption_password) |
| actualbudget (factory) | actualbudget | bank-sync-{name} (CronJob) | bank-sync | 3-edge | 250m | 256Mi | Curl container |
| osm_routing | osm-routing | osrm-foot | osrm-foot | 4-aux | 250m | 256Mi | OSRM needs ~1GB RAM for routing data |
| osm_routing | osm-routing | otp | otp | 4-aux | 250m | 256Mi | 0 replicas (disabled); OTP needs 2Gi+ |
| servarr/prowlarr | servarr | prowlarr | prowlarr | 4-aux | 250m | 256Mi | |
| servarr/qbittorrent | servarr | qbittorrent | qbittorrent | 4-aux | 250m | 256Mi | |
| servarr/flaresolverr | servarr | flaresolverr | flaresolverr | 4-aux | 250m | 256Mi | Chromium-based; likely needs more |
| real-estate-crawler | realestate-crawler | realestate-crawler-ui | realestate-crawler-ui | 4-aux | 250m | 256Mi | 2 replicas |
| real-estate-crawler | realestate-crawler | realestate-crawler-celery | celery-worker | 4-aux | 250m | 256Mi | |
| nextcloud | nextcloud | whiteboard | whiteboard | custom (3-edge) | 250m | 256Mi | Custom LimitRange: max 16 CPU/8Gi |
| nextcloud | nextcloud | nextcloud-backup (CronJob) | backup | custom (3-edge) | 250m | 256Mi | rsync container |
| calibre | calibre | annas-archive-stacks | annas-archive-stacks | 3-edge | 250m | 256Mi | |
| ollama | ollama | ollama-ui | ollama-ui | 2-gpu | 1 | 2Gi | Open WebUI; needs significant mem |
| immich | immich | immich-server | immich-server | 2-gpu | 1 | 2Gi | Photo server; needs resources |
| immich | immich | immich-postgresql | immich-postgresql | 2-gpu | 1 | 2Gi | PostgreSQL; needs resources |
| immich | immich | postgresql-backup (CronJob) | postgresql-backup | 2-gpu | 1 | 2Gi | |
| rybbit | rybbit | rybbit | rybbit | 4-aux | 250m | 256Mi | Node.js backend |
| rybbit | rybbit | rybbit-client | rybbit-client | 4-aux | 250m | 256Mi | |
| poison-fountain | poison-fountain | poison-fetcher (CronJob) | fetcher | 1-cluster | 500m | 512Mi | curl container |
| platform/dbaas | dbaas | mysql-backup (CronJob) | mysql-backup | 1-cluster | 500m | 512Mi | |
| platform/dbaas | dbaas | phpmyadmin | phpmyadmin | 1-cluster | 500m | 512Mi | |
| platform/dbaas | dbaas | pgadmin | pgadmin | 1-cluster | 500m | 512Mi | |
| platform/dbaas | dbaas | postgresql-backup (CronJob) | postgresql-backup | 1-cluster | 500m | 512Mi | |
| platform/xray | xray | xray | xray | 0-core | 500m | 512Mi | |
| platform/wireguard | wireguard | wireguard | sysctl-setup (init) | 0-core | 500m | 512Mi | |
| platform/wireguard | wireguard | wireguard | wireguard | 0-core | 500m | 512Mi | |
| platform/wireguard | wireguard | wireguard | prometheus-exporter | 0-core | 500m | 512Mi | |
| platform/cloudflared | cloudflared | cloudflared | cloudflared | 0-core | 500m | 512Mi | |
| platform/mailserver | mailserver | mailserver | docker-mailserver | 0-core | 500m | 512Mi | Mail server needs more RAM |
| platform/mailserver | mailserver | dovecot-exporter | dovecot-exporter | 0-core | 500m | 512Mi | |
| platform/crowdsec | crowdsec | crowdsec-web | crowdsec-web | 1-cluster | 500m | 512Mi | |
| platform/crowdsec | crowdsec | blocklist-import (CronJob) | blocklist-import | 1-cluster | 500m | 512Mi | |
| platform/k8s-portal | k8s-portal | k8s-portal | portal | 0-core | 500m | 512Mi | |
| platform/monitoring | monitoring | monitor-prometheus (CronJob) | monitor-prometheus | opted-out | N/A | N/A | No LimitRange in monitoring ns |
| platform/redis | redis | redis-backup (CronJob) | redis-backup | 1-cluster | 500m | 512Mi | |
| platform/infra-maint | kube-system | backup-etcd (CronJob) | backup-etcd | N/A | N/A | N/A | kube-system; no Kyverno LimitRange |
| platform/infra-maint | kube-system | backup-purge (CronJob) | backup-purge | N/A | N/A | N/A | |
| platform/infra-maint | kube-system | cleanup-failed (CronJob) | cleanup | N/A | N/A | N/A | |

---

## Section 2: Containers WITH Explicit Resources

| Stack | Namespace | Deployment/Resource | Container | CPU Req | CPU Lim | Mem Req | Mem Lim | Tier | Notes |
|-------|-----------|-------------------|-----------|---------|---------|---------|---------|------|-------|
| blog | website | blog | blog | 250m | 500m | 50Mi | 512Mi | 4-aux | |
| city-guesser | city-guesser | city-guesser | city-guesser | 250m | 500m | 50Mi | 512Mi | 4-aux | |
| coturn | coturn | coturn | coturn | 100m | 1 | 128Mi | 512Mi | 3-edge | |
| kms | kms | kms-web-page | kms-web-page | 500m | 500m | 512Mi | 512Mi | 4-aux | Req==Lim, high for nginx |
| kms | kms | kms (windows) | windows-kms | 1 | 1 | 50Mi | 512Mi | 4-aux | 1 CPU req seems high |
| travel_blog | travel-blog | travel-blog | travel-blog | 250m | 500m | 50Mi | 512Mi | 4-aux | |
| webhook_handler | webhook-handler | webhook-handler | webhook-handler | 250m | 500m | 50Mi | 512Mi | 4-aux | |
| freedify (factory) | freedify | music-{name} | freedify | 100m | 500m | 256Mi | 512Mi | 4-aux | Parameterized; 2 instances |
| health | health | health | health | 100m | 1 | 256Mi | 1Gi | 4-aux | |
| plotting-book | plotting-book | plotting-book | plotting-book | 50m | 500m | 128Mi | 512Mi | 4-aux | |
| frigate | frigate | frigate | frigate | -- | GPU:1 | -- | -- | 2-gpu | Only nvidia.com/gpu limit |
| ebook2audiobook | ebook2audiobook | ebook2audiobook | ebook2audiobook | -- | GPU:1 | -- | -- | 2-gpu | Only nvidia.com/gpu limit |
| ebook2audiobook | ebook2audiobook | audiblez | audiblez | -- | GPU:1 | -- | -- | 2-gpu | Only nvidia.com/gpu; 0 replicas |
| ebook2audiobook | ebook2audiobook | audiblez-web | audiblez-web | -- | GPU:1 | -- | -- | 2-gpu | Only nvidia.com/gpu limit |
| ytdlp | ytdlp | ytdlp | ytdlp | 25m | 500m | 128Mi | 512Mi | 4-aux | |
| ytdlp | ytdlp | yt-highlights | yt-highlights | -- | GPU:1 | -- | -- | 4-aux | GPU workload in aux-tier ns |
| real-estate-crawler | realestate-crawler | realestate-crawler-api | realestate-crawler-api | 50m | 2000m | 128Mi | 1Gi | 4-aux | |
| real-estate-crawler | realestate-crawler | realestate-crawler-celery-beat | celery-beat | 10m | 200m | 64Mi | 256Mi | 4-aux | |
| affine | affine | affine | affine | 100m | 2 | 512Mi | 4Gi | 4-aux | |
| atuin | atuin | atuin | atuin | 50m | 500m | 64Mi | 256Mi | 4-aux | |
| osm_routing | osm-routing | osrm-bicycle | osrm-bicycle | 15m | 250m | 512Mi | 1Gi | 4-aux | |
| paperless-ngx | paperless-ngx | paperless-ngx | paperless-ngx | 100m | 2 | 256Mi | 1Gi | 3-edge | |
| stirling-pdf | stirling-pdf | stirling-pdf | stirling-pdf | 100m | 2 | 256Mi | 1Gi | 4-aux | |
| netbox | netbox | netbox | netbox | 25m | 1 | 64Mi | 512Mi | 4-aux | |
| speedtest | speedtest | speedtest | speedtest | 25m | 500m | 64Mi | 512Mi | 4-aux | |
| meshcentral | meshcentral | meshcentral | meshcentral | 15m | 500m | 64Mi | 384Mi | 4-aux | |
| forgejo | forgejo | forgejo | forgejo | 15m | 500m | 64Mi | 512Mi | 3-edge | |
| dashy | dashy | dashy | dashy | 15m | 500m | 64Mi | 512Mi | 4-aux | |
| url | url | shlink | shlink | 25m | -- | 128Mi | 512Mi | 4-aux | No CPU limit |
| url | url | shlink-web | shlink-web | 250m | 500m | 50Mi | 512Mi | 4-aux | |
| f1-stream | f1-stream | f1-stream | f1-stream | 50m | 500m | 64Mi | 256Mi | 4-aux | |
| calibre | calibre | calibre-web-automated | calibre-web-automated | 50m | 1 | 256Mi | 1Gi | 3-edge | |
| poison-fountain | poison-fountain | poison-fountain | poison-fountain | 10m | 100m | 32Mi | 128Mi | 1-cluster | |
| ollama | ollama | ollama | ollama | 500m | 4 | 4Gi | 12Gi + GPU:1 | 2-gpu | |
| onlyoffice | onlyoffice | onlyoffice-document-server | onlyoffice-document-server | 250m | 8 | 512Mi | 4Gi | 3-edge | Custom LimitRange |
| openclaw | openclaw | openclaw | openclaw | 100m | 2 | 512Mi | 2Gi | 4-aux | |
| openclaw | openclaw | openclaw | modelrelay (sidecar) | 25m | 500m | 64Mi | 256Mi | 4-aux | |
| openclaw | openclaw | cluster-healthcheck (CronJob) | healthcheck | 50m | -- | 64Mi | 128Mi | 4-aux | No CPU limit |
| resume | resume | printer | printer | 50m | 1 | 128Mi | 512Mi | 4-aux | Chromium |
| resume | resume | resume | resume | 25m | 500m | 128Mi | 384Mi | 4-aux | |
| rybbit | rybbit | clickhouse | clickhouse | 100m | 2 | 512Mi | 4Gi | 4-aux | |
| immich | immich | immich-machine-learning | immich-machine-learning | -- | GPU:1 | -- | -- | 2-gpu | Only nvidia.com/gpu limit |
| trading-bot | trading-bot | trading-bot-frontend | dashboard | 10m | 200m | 32Mi | 128Mi | 3-edge | |
| trading-bot | trading-bot | trading-bot-frontend | api-gateway | 50m | 1000m | 128Mi | 512Mi | 3-edge | |
| trading-bot | trading-bot | trading-bot-workers | news-fetcher | 10m | 500m | 64Mi | 256Mi | 3-edge | |
| trading-bot | trading-bot | trading-bot-workers | sentiment-analyzer | 100m | 2000m | 512Mi | 2Gi | 3-edge | |
| trading-bot | trading-bot | trading-bot-workers | signal-generator | 10m | 500m | 64Mi | 256Mi | 3-edge | |
| trading-bot | trading-bot | trading-bot-workers | trade-executor | 10m | 500m | 64Mi | 256Mi | 3-edge | |
| trading-bot | trading-bot | trading-bot-workers | learning-engine | 10m | 500m | 64Mi | 256Mi | 3-edge | |
| trading-bot | trading-bot | trading-bot-workers | market-data | 10m | 500m | 64Mi | 256Mi | 3-edge | |
| platform/technitium | technitium | technitium | technitium | YES | YES | YES | YES | 0-core | Has resources block |
| platform/vaultwarden | vaultwarden | vaultwarden | vaultwarden | YES | YES | YES | YES | 0-core | Has resources block |
| platform/uptime-kuma | uptime-kuma | uptime-kuma | uptime-kuma | YES | YES | YES | YES | 0-core | Has resources block |
| platform/headscale | headscale | headscale | headscale | YES | YES | YES | YES | 0-core | Has resources block |
| platform/headscale | headscale | headscale | headscale-ui | YES | YES | YES | YES | 0-core | Has resources block |
| platform/traefik | traefik | traefik-default-backend | nginx | YES | YES | YES | YES | 0-core | Has resources block |
| platform/traefik | traefik | traefik-local-backend | nginx | YES | YES | YES | YES | 0-core | Has resources block |
| platform/nvidia | nvidia | nvidia-exporter | nvidia-exporter | YES | YES | YES | YES | 2-gpu | Has resources block |
| platform/nvidia | nvidia | nvidia-power-exporter | exporter | YES | YES | YES | YES | 2-gpu | Has resources block |
| platform/monitoring | monitoring | goflow2 | goflow2 | YES | YES | YES | YES | 1-cluster | Has resources block |

---

## Section 3: Helm Chart Deployments (Resources via values.yaml)

These services are deployed via Helm charts. Resource configuration is in the chart's values files, not directly visible in main.tf.

| Stack | Namespace | Chart | Values File | Tier | Notes |
|-------|-----------|-------|-------------|------|-------|
| homepage | homepage | jameswynn/homepage | values.yaml | 4-aux | Check values for resources |
| k8s-dashboard | kubernetes-dashboard | kubernetes-dashboard v7.12.0 | -- | 1-cluster | No custom values for resources |
| reloader | reloader | stakater/reloader | -- | 4-aux | No custom values |
| descheduler | descheduler | descheduler | values.yaml | -- | No tier label |
| woodpecker | woodpecker | woodpecker v3.5.1 | values.yaml | 3-edge | Custom quota; check values |
| nextcloud | nextcloud | nextcloud/nextcloud v8.8.1 | chart_values.yaml | 3-edge | Custom LimitRange/Quota |
| platform/traefik | traefik | traefik | chart values | 0-core | |
| platform/metallb | metallb | metallb | -- | 0-core | |
| platform/redis | redis | bitnami/redis | chart values | 1-cluster | |
| platform/monitoring | monitoring | prometheus, grafana, loki | various | 1-cluster | Opted out of Kyverno quota |
| platform/kyverno | kyverno | kyverno | chart values | 1-cluster | |
| platform/cnpg | cnpg | cnpg-operator | -- | 1-cluster | |
| platform/metrics-server | metrics-server | metrics-server | -- | 1-cluster | |
| platform/vpa | vpa | fairwinds/vpa | -- | 1-cluster | |
| platform/crowdsec | crowdsec | crowdsec | chart values | 1-cluster | |
| platform/nvidia | nvidia | nvidia gpu-operator | chart values | 2-gpu | Opted out of Kyverno quota |
| platform/authentik | authentik | authentik | chart values | 0-core | Custom quota |
| platform/dbaas | dbaas | mysql-operator/innodbcluster | chart values | 1-cluster | Custom quota |

---

## Section 4: High-Risk Findings Summary

### OOM-Kill Risk (containers likely needing more than 256Mi default)

| Container | Namespace | Tier Default Mem | Why It's Risky |
|-----------|-----------|-----------------|----------------|
| sockpuppetbrowser | changedetection | 256Mi | Headless Chromium browser |
| flaresolverr | servarr | 256Mi | Chromium-based solver |
| osrm-foot | osm-routing | 256Mi | OSRM loads routing graph into memory (~500MB+) |
| navidrome | navidrome | 256Mi | Music library indexing |
| linkwarden | linkwarden | 256Mi | Next.js app with screenshot capture |
| n8n | n8n | 256Mi | Workflow automation with many nodes |
| dawarich | dawarich | 256Mi | Rails app |
| hackmd (codimd) | hackmd | 256Mi | Node.js collaborative editor |
| ollama-ui | ollama | 2Gi | Open WebUI; may be fine in GPU tier |
| immich-server | immich | 2Gi | Photo processing server |
| immich-postgresql | immich | 2Gi | PostgreSQL with pgvector |
| docker-mailserver | mailserver | 512Mi | ClamAV, SpamAssassin, etc. |
| audiobookshelf | audiobookshelf | 256Mi | Media server with transcoding |

### GPU Containers with Only nvidia.com/gpu Limit (no CPU/Mem specified)

These get LimitRange defaults for CPU/Mem but only have GPU limits set:

| Container | Namespace | Tier | Gets Default |
|-----------|-----------|------|-------------|
| frigate | frigate | 2-gpu | 1 CPU / 2Gi |
| ebook2audiobook | ebook2audiobook | 2-gpu | 1 CPU / 2Gi |
| audiblez | ebook2audiobook | 2-gpu | 1 CPU / 2Gi |
| audiblez-web | ebook2audiobook | 2-gpu | 1 CPU / 2Gi |
| yt-highlights | ytdlp | 4-aux | 250m / 256Mi (!) |
| immich-machine-learning | immich | 2-gpu | 1 CPU / 2Gi |

**Note**: `yt-highlights` is in the `ytdlp` namespace (4-aux tier) but runs on GPU node. Its default of 256Mi is very low for a Whisper ASR model.

### Containers with No Resources in Core/Cluster Tier (higher defaults but still worth checking)

| Container | Namespace | Tier | Default |
|-----------|-----------|------|---------|
| xray | xray | 0-core | 500m / 512Mi |
| wireguard | wireguard | 0-core | 500m / 512Mi |
| wireguard prometheus-exporter | wireguard | 0-core | 500m / 512Mi |
| cloudflared | cloudflared | 0-core | 500m / 512Mi |
| docker-mailserver | mailserver | 0-core | 500m / 512Mi |
| dovecot-exporter | mailserver | 0-core | 500m / 512Mi |
| k8s-portal | k8s-portal | 0-core | 500m / 512Mi |
| tuya-bridge | tuya-bridge | 1-cluster | 500m / 512Mi |
| phpmyadmin | dbaas | 1-cluster | 500m / 512Mi |
| pgadmin | dbaas | 1-cluster | 500m / 512Mi |
| crowdsec-web | crowdsec | 1-cluster | 500m / 512Mi |

---

## Section 5: Statistics

### Totals

- **Total unique containers audited**: ~120+
- **Containers WITH explicit resources**: ~55
- **Containers WITHOUT explicit resources**: ~65
- **Helm-managed (resources in values)**: ~18 charts

### By Tier (containers without resources)

| Tier | Count | Risk Level |
|------|-------|------------|
| 0-core | 7 | Medium (512Mi default is usually OK) |
| 1-cluster | 7 | Medium |
| 2-gpu | 5 | Low (2Gi default is generous) |
| 3-edge | 8 | High (256Mi can OOM Node/Rails/Java apps) |
| 4-aux | 25+ | High (256Mi is tight for many services) |
| monitoring (opted-out) | 1 | Low (no LimitRange at all) |
| kube-system | 3 | Low (no Kyverno) |

### Recommendations

1. **Immediate action**: Add explicit resources to `sockpuppetbrowser`, `flaresolverr`, `osrm-foot`, `docker-mailserver`, `immich-server`, `immich-postgresql`, `linkwarden`, `n8n`
2. **GPU containers**: Add explicit CPU/Mem alongside nvidia.com/gpu for `frigate`, `ebook2audiobook`, `audiblez-web`, `immich-machine-learning`, `yt-highlights`
3. **Review**: `kms-web-page` has 500m/512Mi request==limit for nginx (wasteful)
4. **CronJobs**: Most CronJob containers lack resources -- acceptable for short-lived jobs but adds to ResourceQuota consumption
