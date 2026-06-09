# Goldilocks VPA Recommendations Audit

**Generated**: 2026-03-01

**Cluster**: k8s-master (v1.34.2)

## Executive Summary

- **Total namespaces**: 101
- **Namespaces with VPA recommendations**: 97
- **Namespaces without VPA**: 4 (gadget, kube-node-lease, kube-public, reverse-proxy)
- **Total VPA objects**: 195
- **Total containers with recommendations**: 200
- **VPA objects without recommendations**: 18

### Top 10 Containers by Recommended Memory (target)

| Rank | Namespace | Deployment | Container | Target Mem | Upper Bound | Current Limit |
|------|-----------|------------|-----------|------------|-------------|---------------|
| 1 | nextcloud | nextcloud | nextcloud | 5.70Gi | 7.39Gi | 6.00Gi |
| 2 | frigate | frigate | frigate | 5.15Gi | 6.65Gi | N/A |
| 3 | monitoring | prometheus-server | prometheus-server | 4.20Gi | 5.43Gi | N/A |
| 4 | monitoring | loki | loki | 3.08Gi | 3.98Gi | 6.00Gi |
| 5 | dbaas | mysql-cluster | mysql | 2.77Gi | 6.90Gi | 2.00Gi |
| 6 | dashy | dashy | dashy | 2.36Gi | 3.23Gi | 512Mi |
| 7 | immich | immich-machine-learning | immich-machine-learning | 2.24Gi | 2.90Gi | N/A |
| 8 | rybbit | clickhouse | clickhouse | 1.91Gi | 2.47Gi | 4.00Gi |
| 9 | trading-bot | trading-bot-workers | sentiment-analyzer | 1.81Gi | 2.35Gi | 2.00Gi |
| 10 | openclaw | openclaw | openclaw | 1.53Gi | 2.11Gi | 2.00Gi |

### Top 10 Containers by Recommended CPU (target)

| Rank | Namespace | Deployment | Container | Target CPU | Upper Bound | Current Limit |
|------|-----------|------------|-----------|------------|-------------|---------------|
| 1 | nextcloud | nextcloud | nextcloud | 2.4 | 3.1 | 16.0 |
| 2 | frigate | frigate | frigate | 1.2 | 1.8 | N/A |
| 3 | rybbit | clickhouse | clickhouse | 1.2 | 1.6 | 2.0 |
| 4 | dbaas | mysql-cluster | mysql | 1.1 | 3.3 | 2.0 |
| 5 | immich | immich-server | immich-server | 920m | 1.2 | N/A |
| 6 | monitoring | loki | loki | 476m | 660m | 1.0 |
| 7 | redis | redis-node | redis | 410m | 900m | 500m |
| 8 | monitoring | alloy | alloy | 296m | 372m | N/A |
| 9 | netbox | netbox | netbox | 203m | 383m | 1.0 |
| 10 | speedtest | speedtest | speedtest | 182m | 418m | 500m |

### Containers Where VPA Recommendation Exceeds Current Limits (>2x)

These containers may be at risk of OOMKill or CPU throttling.

| Namespace | Deployment | Container | VPA Target CPU | Current CPU Limit | Ratio | VPA Target Mem | Current Mem Limit | Ratio |
|-----------|------------|-----------|----------------|-------------------|-------|----------------|-------------------|-------|
| dashy | dashy | dashy | 15m | 500m | 0.0x | 2.36Gi | 512Mi | 4.7x |
| traefik | auth-proxy | nginx | 15m | 50m | 0.3x | 100Mi | 32Mi | 3.1x |
| traefik | bot-block-proxy | nginx | 15m | 50m | 0.3x | 100Mi | 32Mi | 3.1x |
| resume | printer | printer | 15m | 1.0 | 0.0x | 1.29Gi | 512Mi | 2.6x |

### Over-Provisioned Containers (Current Limits > 3x VPA Upper Bound)

These containers have much more resources allocated than VPA observes them needing.

| Namespace | Deployment | Container | VPA Upper CPU | Current CPU Limit | Waste | VPA Upper Mem | Current Mem Limit | Waste |
|-----------|------------|-----------|---------------|-------------------|-------|---------------|-------------------|-------|
| ollama | ollama | ollama | 15m | 4.0 | 266.7x | 335Mi | 12.00Gi | 36.6x |
| onlyoffice | onlyoffice-document-server | onlyoffice-document-server | 45m | 8.0 | 177.8x | 2.10Gi | 4.00Gi | 1.9x |
| trading-bot | trading-bot-workers | sentiment-analyzer | 14m | 2.0 | 142.9x | 2.35Gi | 2.00Gi | 0.9x |
| realestate-crawler | realestate-crawler-api | realestate-crawler-api | 15m | 2.0 | 133.3x | 244Mi | 1.00Gi | 4.2x |
| realestate-crawler | realestate-crawler-celery | celery-worker | 15m | 2.0 | 133.3x | 2.76Gi | 2.00Gi | 0.7x |
| stirling-pdf | stirling-pdf | stirling-pdf | 29m | 2.0 | 69.0x | 1.41Gi | 1.00Gi | 0.7x |
| coturn | coturn | coturn | 15m | 1.0 | 66.7x | 100Mi | 512Mi | 5.1x |
| health | health | health | 15m | 1.0 | 66.7x | 226Mi | 1.00Gi | 4.5x |
| kms | kms | windows-kms | 15m | 1.0 | 66.7x | 100Mi | 512Mi | 5.1x |
| resume | printer | printer | 15m | 1.0 | 66.7x | 1.67Gi | 512Mi | 0.3x |
| servarr | listenarr | listenarr | 15m | 1.0 | 66.7x | 944Mi | 1.00Gi | 1.1x |
| authentik | goauthentik-server | server | 43m | 2.0 | 46.5x | 859Mi | 1.00Gi | 1.2x |
| trading-bot | trading-bot-frontend | api-gateway | 23m | 1.0 | 43.5x | 511Mi | 512Mi | 1.0x |
| nvidia | nvidia-gpu-operator-node-feature-discovery-master | master | 15m | N/A | N/A | 100Mi | 4.00Gi | 41.0x |
| website | blog | blog | 13m | 500m | 38.5x | 50Mi | 512Mi | 10.2x |
| trading-bot | trading-bot-workers | learning-engine | 14m | 500m | 35.7x | 116Mi | 256Mi | 2.2x |
| trading-bot | trading-bot-workers | market-data | 14m | 500m | 35.7x | 180Mi | 256Mi | 1.4x |
| trading-bot | trading-bot-workers | news-fetcher | 14m | 500m | 35.7x | 137Mi | 256Mi | 1.9x |
| trading-bot | trading-bot-workers | signal-generator | 14m | 500m | 35.7x | 228Mi | 256Mi | 1.1x |
| trading-bot | trading-bot-workers | trade-executor | 14m | 500m | 35.7x | 180Mi | 256Mi | 1.4x |
| aiostreams | aiostreams | aiostreams | 15m | 500m | 33.3x | 835Mi | 768Mi | 0.9x |
| city-guesser | city-guesser | city-guesser | 15m | 500m | 33.3x | 100Mi | 512Mi | 5.1x |
| dashy | dashy | dashy | 15m | 500m | 33.3x | 3.23Gi | 512Mi | 0.2x |
| forgejo | forgejo | forgejo | 15m | 500m | 33.3x | 284Mi | 512Mi | 1.8x |
| freedify | music-emo | freedify | 15m | 500m | 33.3x | 135Mi | 512Mi | 3.8x |
| freedify | music-viktor | freedify | 15m | 500m | 33.3x | 116Mi | 512Mi | 4.4x |
| kms | kms-web-page | kms-web-page | 15m | 500m | 33.3x | 100Mi | 512Mi | 5.1x |
| meshcentral | meshcentral | meshcentral | 15m | 500m | 33.3x | 367Mi | 384Mi | 1.0x |
| plotting-book | plotting-book | plotting-book | 15m | 500m | 33.3x | 115Mi | 512Mi | 4.4x |
| resume | resume | resume | 15m | 500m | 33.3x | 279Mi | 384Mi | 1.4x |
| technitium | technitium | technitium | 15m | 500m | 33.3x | 367Mi | 512Mi | 1.4x |
| travel-blog | travel-blog | travel-blog | 15m | 500m | 33.3x | 100Mi | 512Mi | 5.1x |
| url | shlink-web | shlink-web | 15m | 500m | 33.3x | 100Mi | 512Mi | 5.1x |
| webhook-handler | webhook-handler | webhook-handler | 15m | 500m | 33.3x | 100Mi | 512Mi | 5.1x |
| ytdlp | ytdlp | ytdlp | 15m | 500m | 33.3x | 367Mi | 512Mi | 1.4x |
| affine | affine | affine | 63m | 2.0 | 31.7x | 307Mi | 4.00Gi | 13.4x |
| atuin | atuin | atuin | 25m | 500m | 20.0x | 100Mi | 256Mi | 2.6x |
| crowdsec | crowdsec-lapi | crowdsec-lapi | 28m | 500m | 17.9x | 152Mi | 500Mi | 3.3x |
| osm-routing | osrm-bicycle | osrm-bicycle | 15m | 250m | 16.7x | 679Mi | 1.00Gi | 1.5x |
| calibre | calibre-web-automated | calibre-web-automated | 63m | 1.0 | 15.9x | 829Mi | 1.00Gi | 1.2x |
| trading-bot | trading-bot-frontend | dashboard | 14m | 200m | 14.3x | 50Mi | 128Mi | 2.6x |
| realestate-crawler | realestate-crawler-celery-beat | celery-beat | 15m | 200m | 13.3x | 226Mi | 256Mi | 1.1x |
| vaultwarden | vaultwarden | vaultwarden | 15m | 200m | 13.3x | 156Mi | 256Mi | 1.6x |
| monitoring | grafana | grafana | 43m | 500m | 11.6x | 298Mi | 512Mi | 1.7x |
| nvidia | gpu-operator | gpu-operator | 45m | 500m | 11.1x | 100Mi | 350Mi | 3.5x |
| nvidia | nvidia-gpu-operator-node-feature-discovery-gc | gc | 15m | N/A | N/A | 100Mi | 1.00Gi | 10.2x |
| technitium | technitium-secondary | technitium | 49m | 500m | 10.2x | 376Mi | 512Mi | 1.4x |
| cnpg-system | cnpg-cloudnative-pg | manager | 54m | 500m | 9.3x | 286Mi | 256Mi | 0.9x |
| f1-stream | f1-stream | f1-stream | 63m | 500m | 7.9x | 136Mi | 256Mi | 1.9x |
| headscale | headscale | headscale-ui | 14m | 100m | 7.1x | 97Mi | 128Mi | 1.3x |
| headscale | headscale | headscale | 29m | 200m | 6.9x | 136Mi | 256Mi | 1.9x |
| poison-fountain | poison-fountain | poison-fountain | 15m | 100m | 6.7x | 100Mi | 128Mi | 1.3x |
| authentik | goauthentik-worker | worker | 158m | 1.0 | 6.3x | 859Mi | 1.00Gi | 1.2x |
| openclaw | openclaw | openclaw | 385m | 2.0 | 5.2x | 2.11Gi | 2.00Gi | 0.9x |
| paperless-ngx | paperless-ngx | paperless-ngx | 389m | 2.0 | 5.1x | 1.70Gi | 1.00Gi | 0.6x |
| nextcloud | nextcloud | nextcloud | 3.1 | 16.0 | 5.1x | 7.39Gi | 6.00Gi | 0.8x |
| openclaw | openclaw | modelrelay | 99m | 500m | 5.1x | 1.22Gi | 256Mi | 0.2x |

---

## Detailed Per-Namespace VPA Recommendations

### actualbudget

**Deployment: `actualbudget-anca`** (VPA: `goldilocks-actualbudget-anca`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| actualbudget | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| actualbudget | Memory | 121Mi | 100Mi | 156Mi | 121Mi | N/A | N/A |

**Deployment: `actualbudget-emo`** (VPA: `goldilocks-actualbudget-emo`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| actualbudget | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| actualbudget | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

**Deployment: `actualbudget-http-api-anca`** (VPA: `goldilocks-actualbudget-http-api-anca`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| actualbudget | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| actualbudget | Memory | 175Mi | 100Mi | 278Mi | 175Mi | N/A | N/A |

**Deployment: `actualbudget-http-api-emo`** (VPA: `goldilocks-actualbudget-http-api-emo`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| actualbudget | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| actualbudget | Memory | 100Mi | 100Mi | 135Mi | 100Mi | N/A | N/A |

**Deployment: `actualbudget-http-api-viktor`** (VPA: `goldilocks-actualbudget-http-api-viktor`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| actualbudget | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| actualbudget | Memory | 259Mi | 100Mi | 335Mi | 259Mi | N/A | N/A |

**Deployment: `actualbudget-viktor`** (VPA: `goldilocks-actualbudget-viktor`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| actualbudget | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| actualbudget | Memory | 138Mi | 105Mi | 178Mi | 138Mi | N/A | N/A |

**CronJob: `bank-sync-anca`** (VPA: `goldilocks-bank-sync-anca`, mode: `Off`)

_No recommendations available (insufficient data)_

**CronJob: `bank-sync-emo`** (VPA: `goldilocks-bank-sync-emo`, mode: `Off`)

_No recommendations available (insufficient data)_

**CronJob: `bank-sync-viktor`** (VPA: `goldilocks-bank-sync-viktor`, mode: `Off`)

_No recommendations available (insufficient data)_

### affine

**Deployment: `affine`** (VPA: `goldilocks-affine`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| affine | CPU | 35m | 15m | 63m | 35m | 100m | 2.0 |
| affine | Memory | 237Mi | 237Mi | 307Mi | 237Mi | 512Mi | 4.00Gi |

### aiostreams

**Deployment: `aiostreams`** (VPA: `goldilocks-aiostreams`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| aiostreams | CPU | 15m | 15m | 15m | 15m | 50m | 500m |
| aiostreams | Memory | 641Mi | 308Mi | 835Mi | 641Mi | 256Mi | 768Mi |

### atuin

**Deployment: `atuin`** (VPA: `goldilocks-atuin`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| atuin | CPU | 15m | 15m | 25m | 15m | 50m | 500m |
| atuin | Memory | 100Mi | 100Mi | 100Mi | 100Mi | 64Mi | 256Mi |

### audiobookshelf

**Deployment: `audiobookshelf`** (VPA: `goldilocks-audiobookshelf`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| audiobookshelf | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| audiobookshelf | Memory | 121Mi | 100Mi | 157Mi | 121Mi | N/A | N/A |

### authentik

**Deployment: `ak-outpost-authentik-embedded-outpost`** (VPA: `goldilocks-ak-outpost-authentik-embedded-outpost`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| proxy | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| proxy | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

**Deployment: `goauthentik-server`** (VPA: `goldilocks-goauthentik-server`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| server | CPU | 35m | 22m | 43m | 35m | 100m | 2.0 |
| server | Memory | 684Mi | 640Mi | 859Mi | 684Mi | 512Mi | 1.00Gi |

**Deployment: `goauthentik-worker`** (VPA: `goldilocks-goauthentik-worker`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| worker | CPU | 126m | 92m | 158m | 126m | 50m | 1.0 |
| worker | Memory | 600Mi | 422Mi | 859Mi | 600Mi | 384Mi | 1.00Gi |

**Deployment: `pgbouncer`** (VPA: `goldilocks-pgbouncer`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| pgbouncer | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| pgbouncer | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

### calibre

**Deployment: `annas-archive-stacks`** (VPA: `goldilocks-annas-archive-stacks`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| annas-archive-stacks | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| annas-archive-stacks | Memory | 100Mi | 100Mi | 115Mi | 100Mi | N/A | N/A |

**Deployment: `calibre-web-automated`** (VPA: `goldilocks-calibre-web-automated`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| calibre-web-automated | CPU | 35m | 15m | 63m | 35m | 50m | 1.0 |
| calibre-web-automated | Memory | 641Mi | 335Mi | 829Mi | 641Mi | 256Mi | 1.00Gi |

### calico-apiserver

**Deployment: `calico-apiserver`** (VPA: `goldilocks-calico-apiserver`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| calico-apiserver | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| calico-apiserver | Memory | 105Mi | 100Mi | 132Mi | 105Mi | N/A | N/A |

### calico-system

**Deployment: `calico-kube-controllers`** (VPA: `goldilocks-calico-kube-controllers`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| calico-kube-controllers | CPU | 23m | 15m | 29m | 23m | N/A | N/A |
| calico-kube-controllers | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

**DaemonSet: `calico-node`** (VPA: `goldilocks-calico-node`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| calico-node | CPU | 63m | 34m | 79m | 63m | N/A | N/A |
| calico-node | Memory | 215Mi | 156Mi | 270Mi | 215Mi | N/A | N/A |

**Deployment: `calico-typha`** (VPA: `goldilocks-calico-typha`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| calico-typha | CPU | 15m | 15m | 26m | 15m | N/A | N/A |
| calico-typha | Memory | 100Mi | 100Mi | 182Mi | 100Mi | N/A | N/A |

**DaemonSet: `csi-node-driver`** (VPA: `goldilocks-csi-node-driver`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| calico-csi | CPU | 11m | 10m | 13m | 11m | N/A | N/A |
| calico-csi | Memory | 50Mi | 50Mi | 50Mi | 50Mi | N/A | N/A |
| csi-node-driver-registrar | CPU | 11m | 10m | 13m | 11m | N/A | N/A |
| csi-node-driver-registrar | Memory | 50Mi | 50Mi | 50Mi | 50Mi | N/A | N/A |

### changedetection

**Deployment: `changedetection`** (VPA: `goldilocks-changedetection`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| changedetection | CPU | 11m | 10m | 14m | 11m | N/A | N/A |
| changedetection | Memory | 105Mi | 105Mi | 135Mi | 105Mi | N/A | N/A |
| sockpuppetbrowser | CPU | 11m | 10m | 14m | 11m | N/A | N/A |
| sockpuppetbrowser | Memory | 61Mi | 61Mi | 78Mi | 61Mi | N/A | N/A |

### city-guesser

**Deployment: `city-guesser`** (VPA: `goldilocks-city-guesser`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| city-guesser | CPU | 15m | 15m | 15m | 15m | 250m | 500m |
| city-guesser | Memory | 100Mi | 100Mi | 100Mi | 100Mi | 50Mi | 512Mi |

### cloudflared

**Deployment: `cloudflared`** (VPA: `goldilocks-cloudflared`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| cloudflared | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| cloudflared | Memory | 100Mi | 100Mi | 112Mi | 100Mi | N/A | N/A |

### cnpg-system

**Deployment: `cnpg-cloudnative-pg`** (VPA: `goldilocks-cnpg-cloudnative-pg`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| manager | CPU | 23m | 15m | 54m | 23m | 100m | 500m |
| manager | Memory | 121Mi | 121Mi | 286Mi | 121Mi | 128Mi | 256Mi |

### coturn

**Deployment: `coturn`** (VPA: `goldilocks-coturn`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| coturn | CPU | 15m | 15m | 15m | 15m | 100m | 1.0 |
| coturn | Memory | 100Mi | 100Mi | 100Mi | 100Mi | 128Mi | 512Mi |

### crowdsec

**DaemonSet: `crowdsec-agent`** (VPA: `goldilocks-crowdsec-agent`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| crowdsec-agent | CPU | 23m | 15m | 28m | 23m | N/A | N/A |
| crowdsec-agent | Memory | 105Mi | 100Mi | 152Mi | 105Mi | N/A | N/A |

**CronJob: `crowdsec-blocklist-import`** (VPA: `goldilocks-crowdsec-blocklist-import`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| blocklist-import | CPU | 35m | 15m | 15.5 | 35m | N/A | N/A |
| blocklist-import | Memory | 100Mi | 100Mi | 32.19Gi | 100Mi | N/A | N/A |

**Deployment: `crowdsec-lapi`** (VPA: `goldilocks-crowdsec-lapi`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| crowdsec-lapi | CPU | 23m | 15m | 28m | 23m | 500m | 500m |
| crowdsec-lapi | Memory | 121Mi | 100Mi | 152Mi | 121Mi | 500Mi | 500Mi |

**Deployment: `crowdsec-web`** (VPA: `goldilocks-crowdsec-web`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| crowdsec-web | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| crowdsec-web | Memory | 100Mi | 100Mi | 631Mi | 100Mi | N/A | N/A |

### cyberchef

**Deployment: `cyberchef`** (VPA: `goldilocks-cyberchef`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| cyberchef | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| cyberchef | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

### dashy

**Deployment: `dashy`** (VPA: `goldilocks-dashy`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| dashy | CPU | 15m | 15m | 15m | 15m | 15m | 500m |
| dashy | Memory | 2.36Gi | 1.29Gi | 3.23Gi | 2.36Gi | 64Mi | 512Mi |

### dawarich

**Deployment: `dawarich`** (VPA: `goldilocks-dawarich`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| dawarich | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| dawarich | Memory | 600Mi | 560Mi | 775Mi | 600Mi | N/A | N/A |

### dbaas

**CronJob: `mysql-backup`** (VPA: `goldilocks-mysql-backup`, mode: `Off`)

_No recommendations available (insufficient data)_

**StatefulSet: `mysql-cluster`** (VPA: `goldilocks-mysql-cluster`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| mysql | CPU | 1.1 | 77m | 3.3 | 1.1 | 250m | 2.0 |
| mysql | Memory | 2.77Gi | 1.22Gi | 6.90Gi | 2.77Gi | 1.00Gi | 2.00Gi |
| sidecar | CPU | 11m | 10m | 27m | 11m | N/A | N/A |
| sidecar | Memory | 215Mi | 214Mi | 535Mi | 215Mi | N/A | N/A |

**Deployment: `pgadmin`** (VPA: `goldilocks-pgadmin`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| pgadmin | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| pgadmin | Memory | 392Mi | 362Mi | 507Mi | 392Mi | N/A | N/A |

**Deployment: `phpmyadmin`** (VPA: `goldilocks-phpmyadmin`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| phpmyadmin | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| phpmyadmin | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

**CronJob: `postgresql-backup`** (VPA: `goldilocks-postgresql-backup`, mode: `Off`)

_No recommendations available (insufficient data)_

### default

**CronJob: `backup-etcd`** (VPA: `goldilocks-backup-etcd`, mode: `Off`)

_No recommendations available (insufficient data)_

**CronJob: `cleanup-failed-pods`** (VPA: `goldilocks-cleanup-failed-pods`, mode: `Off`)

_No recommendations available (insufficient data)_

**CronJob: `monitor-prometheus`** (VPA: `goldilocks-monitor-prometheus`, mode: `Off`)

_No recommendations available (insufficient data)_

### descheduler

**CronJob: `descheduler`** (VPA: `goldilocks-descheduler`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| descheduler | CPU | 126m | 51m | 14.1 | 126m | N/A | N/A |
| descheduler | Memory | 100Mi | 100Mi | 8.14Gi | 100Mi | N/A | N/A |

### diun

**Deployment: `diun`** (VPA: `goldilocks-diun`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| diun | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| diun | Memory | 100Mi | 100Mi | 116Mi | 100Mi | N/A | N/A |

### ebook2audiobook

**Deployment: `audiblez`** (VPA: `goldilocks-audiblez`, mode: `Off`)

_No recommendations available (insufficient data)_

**Deployment: `audiblez-web`** (VPA: `goldilocks-audiblez-web`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| audiblez-web | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| audiblez-web | Memory | 138Mi | 121Mi | 178Mi | 138Mi | N/A | N/A |

**Deployment: `ebook2audiobook`** (VPA: `goldilocks-ebook2audiobook`, mode: `Off`)

_No recommendations available (insufficient data)_

### echo

**Deployment: `echo`** (VPA: `goldilocks-echo`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| echo | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| echo | Memory | 105Mi | 100Mi | 132Mi | 105Mi | N/A | N/A |

### excalidraw

**Deployment: `excalidraw`** (VPA: `goldilocks-excalidraw`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| excalidraw | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| excalidraw | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

### f1-stream

**Deployment: `f1-stream`** (VPA: `goldilocks-f1-stream`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| f1-stream | CPU | 15m | 15m | 63m | 15m | 50m | 500m |
| f1-stream | Memory | 105Mi | 100Mi | 136Mi | 105Mi | 64Mi | 256Mi |

### forgejo

**Deployment: `forgejo`** (VPA: `goldilocks-forgejo`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| forgejo | CPU | 15m | 15m | 15m | 15m | 15m | 500m |
| forgejo | Memory | 215Mi | 121Mi | 284Mi | 215Mi | 64Mi | 512Mi |

### freedify

**Deployment: `music-emo`** (VPA: `goldilocks-music-emo`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| freedify | CPU | 15m | 15m | 15m | 15m | 100m | 500m |
| freedify | Memory | 105Mi | 105Mi | 135Mi | 105Mi | 256Mi | 512Mi |

**Deployment: `music-viktor`** (VPA: `goldilocks-music-viktor`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| freedify | CPU | 15m | 15m | 15m | 15m | 100m | 500m |
| freedify | Memory | 100Mi | 100Mi | 116Mi | 100Mi | 256Mi | 512Mi |

### freshrss

**Deployment: `freshrss`** (VPA: `goldilocks-freshrss`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| freshrss | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| freshrss | Memory | 100Mi | 100Mi | 116Mi | 100Mi | N/A | N/A |

### frigate

**Deployment: `frigate`** (VPA: `goldilocks-frigate`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| frigate | CPU | 1.2 | 1.0 | 1.8 | 1.2 | N/A | N/A |
| frigate | Memory | 5.15Gi | 4.42Gi | 6.65Gi | 5.15Gi | N/A | N/A |

### hackmd

**Deployment: `hackmd`** (VPA: `goldilocks-hackmd`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| codimd | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| codimd | Memory | 138Mi | 138Mi | 181Mi | 138Mi | N/A | N/A |

### headscale

**Deployment: `headscale`** (VPA: `goldilocks-headscale`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| headscale | CPU | 11m | 10m | 29m | 11m | 50m | 200m |
| headscale | Memory | 105Mi | 89Mi | 136Mi | 105Mi | 64Mi | 256Mi |
| headscale-ui | CPU | 11m | 10m | 14m | 11m | 25m | 100m |
| headscale-ui | Memory | 75Mi | 75Mi | 97Mi | 75Mi | 32Mi | 128Mi |

### health

**Deployment: `health`** (VPA: `goldilocks-health`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| health | CPU | 15m | 15m | 15m | 15m | 100m | 1.0 |
| health | Memory | 175Mi | 174Mi | 226Mi | 175Mi | 256Mi | 1.00Gi |

### homepage

**Deployment: `homepage`** (VPA: `goldilocks-homepage`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| homepage | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| homepage | Memory | 121Mi | 105Mi | 156Mi | 121Mi | N/A | N/A |

### immich

**Deployment: `immich-frame`** (VPA: `goldilocks-immich-frame`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| immich-frame | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| immich-frame | Memory | 121Mi | 121Mi | 158Mi | 121Mi | N/A | N/A |

**Deployment: `immich-machine-learning`** (VPA: `goldilocks-immich-machine-learning`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| immich-machine-learning | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| immich-machine-learning | Memory | 2.24Gi | 1.37Gi | 2.90Gi | 2.24Gi | N/A | N/A |

**Deployment: `immich-postgresql`** (VPA: `goldilocks-immich-postgresql`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| immich-postgresql | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| immich-postgresql | Memory | 776Mi | 362Mi | 1.27Gi | 776Mi | N/A | N/A |

**Deployment: `immich-server`** (VPA: `goldilocks-immich-server`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| immich-server | CPU | 920m | 15m | 1.2 | 920m | N/A | N/A |
| immich-server | Memory | 991Mi | 825Mi | 1.27Gi | 991Mi | N/A | N/A |

**CronJob: `postgresql-backup`** (VPA: `goldilocks-postgresql-backup`, mode: `Off`)

_No recommendations available (insufficient data)_

### isponsorblocktv

**Deployment: `isponsorblocktv-vermont`** (VPA: `goldilocks-isponsorblocktv-vermont`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| isponsorblocktv-vermont | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| isponsorblocktv-vermont | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

### jsoncrack

**Deployment: `jsoncrack`** (VPA: `goldilocks-jsoncrack`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| jsoncrack | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| jsoncrack | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

### k8s-portal

**Deployment: `k8s-portal`** (VPA: `goldilocks-k8s-portal`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| portal | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| portal | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

### kms

**Deployment: `kms`** (VPA: `goldilocks-kms`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| windows-kms | CPU | 15m | 15m | 15m | 15m | 1.0 | 1.0 |
| windows-kms | Memory | 100Mi | 100Mi | 100Mi | 100Mi | 50Mi | 512Mi |

**Deployment: `kms-web-page`** (VPA: `goldilocks-kms-web-page`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| kms-web-page | CPU | 15m | 15m | 15m | 15m | 500m | 500m |
| kms-web-page | Memory | 100Mi | 100Mi | 100Mi | 100Mi | 512Mi | 512Mi |

### kube-system

**Deployment: `coredns`** (VPA: `goldilocks-coredns`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| coredns | CPU | 15m | 15m | 15m | 15m | 100m | N/A |
| coredns | Memory | 100Mi | 100Mi | 100Mi | 100Mi | 70Mi | 170Mi |

**DaemonSet: `kube-proxy`** (VPA: `goldilocks-kube-proxy`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| kube-proxy | CPU | 23m | 15m | 43m | 23m | N/A | N/A |
| kube-proxy | Memory | 105Mi | 100Mi | 132Mi | 105Mi | N/A | N/A |

### kured

**DaemonSet: `kured`** (VPA: `goldilocks-kured`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| kured | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| kured | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

### kyverno

**Deployment: `kyverno-admission-controller`** (VPA: `goldilocks-kyverno-admission-controller`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| kyverno | CPU | 23m | 15m | 43m | 23m | 100m | N/A |
| kyverno | Memory | 215Mi | 105Mi | 270Mi | 215Mi | 128Mi | 768Mi |

**Deployment: `kyverno-background-controller`** (VPA: `goldilocks-kyverno-background-controller`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| controller | CPU | 15m | 15m | 15m | 15m | 100m | N/A |
| controller | Memory | 156Mi | 121Mi | 202Mi | 156Mi | 64Mi | 128Mi |

**Deployment: `kyverno-cleanup-controller`** (VPA: `goldilocks-kyverno-cleanup-controller`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| controller | CPU | 23m | 15m | 29m | 23m | 100m | N/A |
| controller | Memory | 138Mi | 100Mi | 179Mi | 138Mi | 64Mi | 128Mi |

**Job: `kyverno-migrate-resources`** (VPA: `goldilocks-kyverno-migrate-resources`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| kubectl | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| kubectl | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

**Deployment: `kyverno-reports-controller`** (VPA: `goldilocks-kyverno-reports-controller`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| controller | CPU | 63m | 15m | 163m | 63m | 100m | N/A |
| controller | Memory | 156Mi | 100Mi | 202Mi | 156Mi | 64Mi | 128Mi |

### linkwarden

**Deployment: `linkwarden`** (VPA: `goldilocks-linkwarden`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| linkwarden | CPU | 15m | 15m | 45m | 15m | N/A | N/A |
| linkwarden | Memory | 878Mi | 776Mi | 1.11Gi | 878Mi | N/A | N/A |

### local-path-storage

**Deployment: `local-path-provisioner`** (VPA: `goldilocks-local-path-provisioner`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| local-path-provisioner | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| local-path-provisioner | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

### mailserver

**Deployment: `mailserver`** (VPA: `goldilocks-mailserver`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| docker-mailserver | CPU | 23m | 10m | 45m | 23m | N/A | N/A |
| docker-mailserver | Memory | 309Mi | 215Mi | 399Mi | 309Mi | N/A | N/A |
| dovecot-exporter | CPU | 11m | 10m | 14m | 11m | N/A | N/A |
| dovecot-exporter | Memory | 50Mi | 50Mi | 50Mi | 50Mi | N/A | N/A |

**Deployment: `roundcubemail`** (VPA: `goldilocks-roundcubemail`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| roundcube | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| roundcube | Memory | 105Mi | 100Mi | 135Mi | 105Mi | N/A | N/A |

### matrix

**Deployment: `matrix`** (VPA: `goldilocks-matrix`, mode: `Off`)

_No recommendations available (insufficient data)_

### meshcentral

**Deployment: `meshcentral`** (VPA: `goldilocks-meshcentral`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| meshcentral | CPU | 15m | 15m | 15m | 15m | 25m | 500m |
| meshcentral | Memory | 259Mi | 215Mi | 367Mi | 259Mi | 128Mi | 384Mi |

### metallb-system

**Deployment: `controller`** (VPA: `goldilocks-controller`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| controller | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| controller | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

**DaemonSet: `speaker`** (VPA: `goldilocks-speaker`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| speaker | CPU | 23m | 15m | 28m | 23m | N/A | N/A |
| speaker | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

### metrics-server

**Deployment: `metrics-server`** (VPA: `goldilocks-metrics-server`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| metrics-server | CPU | 15m | 15m | 15m | 15m | 100m | N/A |
| metrics-server | Memory | 100Mi | 100Mi | 100Mi | 100Mi | 200Mi | N/A |

### monitoring

**DaemonSet: `alloy`** (VPA: `goldilocks-alloy`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| alloy | CPU | 296m | 48m | 372m | 296m | N/A | N/A |
| alloy | Memory | 561Mi | 237Mi | 705Mi | 561Mi | N/A | N/A |
| config-reloader | CPU | 11m | 10m | 13m | 11m | N/A | N/A |
| config-reloader | Memory | 61Mi | 50Mi | 76Mi | 61Mi | N/A | N/A |

**DaemonSet: `caretta`** (VPA: `goldilocks-caretta`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| caretta | CPU | 15m | 15m | 45m | 15m | N/A | N/A |
| caretta | Memory | 422Mi | 391Mi | 899Mi | 422Mi | N/A | N/A |

**Deployment: `goflow2`** (VPA: `goldilocks-goflow2`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| goflow2 | CPU | 23m | 15m | 87m | 23m | 50m | 200m |
| goflow2 | Memory | 100Mi | 100Mi | 118Mi | 100Mi | 64Mi | 256Mi |

**Deployment: `grafana`** (VPA: `goldilocks-grafana`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| grafana | CPU | 35m | 22m | 43m | 35m | 50m | 500m |
| grafana | Memory | 215Mi | 138Mi | 298Mi | 215Mi | 128Mi | 512Mi |
| grafana-sc-dashboard | CPU | 11m | 10m | 13m | 11m | N/A | N/A |
| grafana-sc-dashboard | Memory | 105Mi | 89Mi | 132Mi | 105Mi | N/A | N/A |
| grafana-sc-datasources | CPU | 11m | 10m | 13m | 11m | N/A | N/A |
| grafana-sc-datasources | Memory | 89Mi | 89Mi | 132Mi | 89Mi | N/A | N/A |

**Deployment: `idrac-redfish-exporter`** (VPA: `goldilocks-idrac-redfish-exporter`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| redfish-exporter | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| redfish-exporter | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

**StatefulSet: `loki`** (VPA: `goldilocks-loki`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| loki | CPU | 476m | 62m | 660m | 476m | 250m | 1.0 |
| loki | Memory | 3.08Gi | 1.91Gi | 3.98Gi | 3.08Gi | 4.00Gi | 6.00Gi |
| loki-sc-rules | CPU | 11m | 10m | 14m | 11m | N/A | N/A |
| loki-sc-rules | Memory | 121Mi | 121Mi | 156Mi | 121Mi | N/A | N/A |

**DaemonSet: `loki-canary`** (VPA: `goldilocks-loki-canary`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| loki-canary | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| loki-canary | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

**StatefulSet: `prometheus-alertmanager`** (VPA: `goldilocks-prometheus-alertmanager`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| alertmanager | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| alertmanager | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

**Deployment: `prometheus-kube-state-metrics`** (VPA: `goldilocks-prometheus-kube-state-metrics`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| kube-state-metrics | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| kube-state-metrics | Memory | 156Mi | 100Mi | 201Mi | 156Mi | N/A | N/A |

**DaemonSet: `prometheus-prometheus-node-exporter`** (VPA: `goldilocks-prometheus-prometheus-node-exporter`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| node-exporter | CPU | 23m | 15m | 28m | 23m | N/A | N/A |
| node-exporter | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

**Deployment: `prometheus-prometheus-pushgateway`** (VPA: `goldilocks-prometheus-prometheus-pushgateway`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| pushgateway | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| pushgateway | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

**Deployment: `prometheus-server`** (VPA: `goldilocks-prometheus-server`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| prometheus-server | CPU | 93m | 34m | 163m | 93m | N/A | N/A |
| prometheus-server | Memory | 4.20Gi | 4.19Gi | 5.43Gi | 4.20Gi | N/A | N/A |
| prometheus-server-configmap-reload | CPU | 11m | 10m | 14m | 11m | N/A | N/A |
| prometheus-server-configmap-reload | Memory | 61Mi | 61Mi | 78Mi | 61Mi | N/A | N/A |

**Deployment: `proxmox-exporter`** (VPA: `goldilocks-proxmox-exporter`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| proxmox-exporter | CPU | 35m | 15m | 45m | 35m | N/A | N/A |
| proxmox-exporter | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

**Deployment: `snmp-exporter`** (VPA: `goldilocks-snmp-exporter`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| snmp-exporter | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| snmp-exporter | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

**DaemonSet: `sysctl-inotify`** (VPA: `goldilocks-sysctl-inotify`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| pause | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| pause | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

### mysql-operator

**Deployment: `mysql-operator`** (VPA: `goldilocks-mysql-operator`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| mysql-operator | CPU | 35m | 15m | 147m | 35m | N/A | N/A |
| mysql-operator | Memory | 309Mi | 307Mi | 926Mi | 309Mi | N/A | N/A |

### n8n

**Deployment: `n8n`** (VPA: `goldilocks-n8n`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| n8n | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| n8n | Memory | 641Mi | 422Mi | 830Mi | 641Mi | N/A | N/A |

### navidrome

**Deployment: `navidrome`** (VPA: `goldilocks-navidrome`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| navidrome | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| navidrome | Memory | 156Mi | 100Mi | 202Mi | 156Mi | N/A | N/A |

### netbox

**Deployment: `netbox`** (VPA: `goldilocks-netbox`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| netbox | CPU | 203m | 15m | 383m | 203m | 25m | 1.0 |
| netbox | Memory | 641Mi | 560Mi | 829Mi | 641Mi | 64Mi | 512Mi |

### networking-toolbox

**Deployment: `networking-toolbox`** (VPA: `goldilocks-networking-toolbox`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| networking-toolbox | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| networking-toolbox | Memory | 105Mi | 100Mi | 152Mi | 105Mi | N/A | N/A |

### nextcloud

**Deployment: `nextcloud`** (VPA: `goldilocks-nextcloud`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| nextcloud | CPU | 2.4 | 34m | 3.1 | 2.4 | 100m | 16.0 |
| nextcloud | Memory | 5.70Gi | 1.37Gi | 7.39Gi | 5.70Gi | 1.00Gi | 6.00Gi |
| nextcloud-cron | CPU | 11m | 10m | 101m | 11m | N/A | N/A |
| nextcloud-cron | Memory | 121Mi | 61Mi | 157Mi | 121Mi | N/A | N/A |

**CronJob: `nextcloud-backup`** (VPA: `goldilocks-nextcloud-backup`, mode: `Off`)

_No recommendations available (insufficient data)_

**Deployment: `whiteboard`** (VPA: `goldilocks-whiteboard`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| whiteboard | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| whiteboard | Memory | 156Mi | 156Mi | 201Mi | 156Mi | N/A | N/A |

### ntfy

**Deployment: `ntfy`** (VPA: `goldilocks-ntfy`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| ntfy | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| ntfy | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

### nvidia

**DaemonSet: `gpu-feature-discovery`** (VPA: `goldilocks-gpu-feature-discovery`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| config-manager | CPU | 11m | 10m | 14m | 11m | N/A | N/A |
| config-manager | Memory | 50Mi | 50Mi | 50Mi | 50Mi | N/A | N/A |
| gpu-feature-discovery | CPU | 11m | 10m | 14m | 11m | N/A | N/A |
| gpu-feature-discovery | Memory | 89Mi | 89Mi | 115Mi | 89Mi | N/A | N/A |

**Deployment: `gpu-operator`** (VPA: `goldilocks-gpu-operator`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| gpu-operator | CPU | 23m | 22m | 45m | 23m | 200m | 500m |
| gpu-operator | Memory | 100Mi | 100Mi | 100Mi | 100Mi | 100Mi | 350Mi |

**DaemonSet: `gpu-pod-exporter`** (VPA: `goldilocks-gpu-pod-exporter`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| exporter | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| exporter | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

**DaemonSet: `nvidia-container-toolkit-daemonset`** (VPA: `goldilocks-nvidia-container-toolkit-daemonset`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| nvidia-container-toolkit-ctr | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| nvidia-container-toolkit-ctr | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

**DaemonSet: `nvidia-dcgm-exporter`** (VPA: `goldilocks-nvidia-dcgm-exporter`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| nvidia-dcgm-exporter | CPU | 23m | 22m | 29m | 23m | N/A | N/A |
| nvidia-dcgm-exporter | Memory | 641Mi | 640Mi | 828Mi | 641Mi | N/A | N/A |

**DaemonSet: `nvidia-device-plugin-daemonset`** (VPA: `goldilocks-nvidia-device-plugin-daemonset`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| config-manager | CPU | 11m | 10m | 14m | 11m | N/A | N/A |
| config-manager | Memory | 50Mi | 50Mi | 50Mi | 50Mi | N/A | N/A |
| nvidia-device-plugin | CPU | 11m | 10m | 14m | 11m | N/A | N/A |
| nvidia-device-plugin | Memory | 50Mi | 50Mi | 61Mi | 50Mi | N/A | N/A |

**DaemonSet: `nvidia-driver-daemonset`** (VPA: `goldilocks-nvidia-driver-daemonset`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| nvidia-driver-ctr | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| nvidia-driver-ctr | Memory | 1.37Gi | 1.37Gi | 1.77Gi | 1.37Gi | N/A | N/A |

**Deployment: `nvidia-exporter`** (VPA: `goldilocks-nvidia-exporter`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| nvidia-exporter | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| nvidia-exporter | Memory | 175Mi | 121Mi | 226Mi | 175Mi | N/A | N/A |

**Deployment: `nvidia-gpu-operator-node-feature-discovery-gc`** (VPA: `goldilocks-nvidia-gpu-operator-node-feature-discovery-gc`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| gc | CPU | 15m | 15m | 15m | 15m | 10m | N/A |
| gc | Memory | 100Mi | 100Mi | 100Mi | 100Mi | 128Mi | 1.00Gi |

**Deployment: `nvidia-gpu-operator-node-feature-discovery-master`** (VPA: `goldilocks-nvidia-gpu-operator-node-feature-discovery-master`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| master | CPU | 15m | 15m | 15m | 15m | 100m | N/A |
| master | Memory | 100Mi | 100Mi | 100Mi | 100Mi | 128Mi | 4.00Gi |

**DaemonSet: `nvidia-gpu-operator-node-feature-discovery-worker`** (VPA: `goldilocks-nvidia-gpu-operator-node-feature-discovery-worker`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| worker | CPU | 15m | 15m | 28m | 15m | N/A | N/A |
| worker | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

**DaemonSet: `nvidia-operator-validator`** (VPA: `goldilocks-nvidia-operator-validator`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| nvidia-operator-validator | CPU | 15m | 15m | 33m | 15m | N/A | N/A |
| nvidia-operator-validator | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

### ollama

**Deployment: `ollama`** (VPA: `goldilocks-ollama`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| ollama | CPU | 15m | 15m | 15m | 15m | 500m | 4.0 |
| ollama | Memory | 259Mi | 100Mi | 335Mi | 259Mi | 4.00Gi | 12.00Gi |

**Deployment: `ollama-ui`** (VPA: `goldilocks-ollama-ui`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| ollama-ui | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| ollama-ui | Memory | 1.15Gi | 1.15Gi | 1.49Gi | 1.15Gi | N/A | N/A |

### onlyoffice

**Deployment: `onlyoffice-document-server`** (VPA: `goldilocks-onlyoffice-document-server`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| onlyoffice-document-server | CPU | 35m | 15m | 45m | 35m | 250m | 8.0 |
| onlyoffice-document-server | Memory | 1.29Gi | 1.22Gi | 2.10Gi | 1.29Gi | 512Mi | 4.00Gi |

### openclaw

**CronJob: `cluster-healthcheck`** (VPA: `goldilocks-cluster-healthcheck`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| healthcheck | CPU | 35m | 15m | 5.1 | 35m | N/A | N/A |
| healthcheck | Memory | 100Mi | 100Mi | 10.56Gi | 100Mi | N/A | N/A |

**Deployment: `openclaw`** (VPA: `goldilocks-openclaw`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| modelrelay | CPU | 11m | 10m | 99m | 11m | 25m | 500m |
| modelrelay | Memory | 89Mi | 73Mi | 1.22Gi | 89Mi | 64Mi | 256Mi |
| openclaw | CPU | 109m | 10m | 385m | 109m | 100m | 2.0 |
| openclaw | Memory | 1.53Gi | 990Mi | 2.11Gi | 1.53Gi | 512Mi | 2.00Gi |

### osm-routing

**Deployment: `osrm-bicycle`** (VPA: `goldilocks-osrm-bicycle`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| osrm-bicycle | CPU | 15m | 15m | 15m | 15m | 15m | 250m |
| osrm-bicycle | Memory | 454Mi | 454Mi | 679Mi | 454Mi | 512Mi | 1.00Gi |

**Deployment: `osrm-foot`** (VPA: `goldilocks-osrm-foot`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| osrm-foot | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| osrm-foot | Memory | 454Mi | 422Mi | 590Mi | 454Mi | N/A | N/A |

**Deployment: `otp`** (VPA: `goldilocks-otp`, mode: `Off`)

_No recommendations available (insufficient data)_

### owntracks

**Deployment: `owntracks`** (VPA: `goldilocks-owntracks`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| owntracks | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| owntracks | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

### paperless-ngx

**Deployment: `paperless-ngx`** (VPA: `goldilocks-paperless-ngx`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| paperless-ngx | CPU | 35m | 15m | 389m | 35m | 100m | 2.0 |
| paperless-ngx | Memory | 1.22Gi | 121Mi | 1.70Gi | 1.22Gi | 256Mi | 1.00Gi |

### plotting-book

**Deployment: `plotting-book`** (VPA: `goldilocks-plotting-book`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| plotting-book | CPU | 15m | 15m | 15m | 15m | 50m | 500m |
| plotting-book | Memory | 100Mi | 100Mi | 115Mi | 100Mi | 128Mi | 512Mi |

### poison-fountain

**Deployment: `poison-fountain`** (VPA: `goldilocks-poison-fountain`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| poison-fountain | CPU | 15m | 15m | 15m | 15m | 10m | 100m |
| poison-fountain | Memory | 100Mi | 100Mi | 100Mi | 100Mi | 32Mi | 128Mi |

**CronJob: `poison-fountain-fetcher`** (VPA: `goldilocks-poison-fountain-fetcher`, mode: `Off`)

_No recommendations available (insufficient data)_

### privatebin

**Deployment: `privatebin`** (VPA: `goldilocks-privatebin`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| privatebin | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| privatebin | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

### realestate-crawler

**Deployment: `realestate-crawler-api`** (VPA: `goldilocks-realestate-crawler-api`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| realestate-crawler-api | CPU | 15m | 15m | 15m | 15m | 50m | 2.0 |
| realestate-crawler-api | Memory | 175Mi | 156Mi | 244Mi | 175Mi | 128Mi | 1.00Gi |

**Deployment: `realestate-crawler-celery`** (VPA: `goldilocks-realestate-crawler-celery`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| celery-worker | CPU | 15m | 15m | 15m | 15m | 100m | 2.0 |
| celery-worker | Memory | 933Mi | 728Mi | 2.76Gi | 933Mi | 512Mi | 2.00Gi |

**Deployment: `realestate-crawler-celery-beat`** (VPA: `goldilocks-realestate-crawler-celery-beat`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| celery-beat | CPU | 15m | 15m | 15m | 15m | 10m | 200m |
| celery-beat | Memory | 175Mi | 174Mi | 226Mi | 175Mi | 64Mi | 256Mi |

**Deployment: `realestate-crawler-ui`** (VPA: `goldilocks-realestate-crawler-ui`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| realestate-crawler-ui | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| realestate-crawler-ui | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

### redis

**CronJob: `redis-backup`** (VPA: `goldilocks-redis-backup`, mode: `Off`)

_No recommendations available (insufficient data)_

**StatefulSet: `redis-node`** (VPA: `goldilocks-redis-node`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| redis | CPU | 410m | 48m | 900m | 410m | 50m | 500m |
| redis | Memory | 61Mi | 50Mi | 123Mi | 61Mi | 64Mi | 256Mi |
| sentinel | CPU | 35m | 34m | 71m | 35m | 50m | 200m |
| sentinel | Memory | 50Mi | 50Mi | 70Mi | 50Mi | 64Mi | 128Mi |

### reloader

**Deployment: `reloader-reloader`** (VPA: `goldilocks-reloader-reloader`, mode: `Off`)

_No recommendations available (insufficient data)_

### resume

**Deployment: `printer`** (VPA: `goldilocks-printer`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| printer | CPU | 15m | 15m | 15m | 15m | 50m | 1.0 |
| printer | Memory | 1.29Gi | 392Mi | 1.67Gi | 1.29Gi | 128Mi | 512Mi |

**Deployment: `resume`** (VPA: `goldilocks-resume`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| resume | CPU | 15m | 15m | 15m | 15m | 25m | 500m |
| resume | Memory | 215Mi | 156Mi | 279Mi | 215Mi | 128Mi | 384Mi |

### rybbit

**Deployment: `clickhouse`** (VPA: `goldilocks-clickhouse`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| clickhouse | CPU | 1.2 | 1.0 | 1.6 | 1.2 | 100m | 2.0 |
| clickhouse | Memory | 1.91Gi | 1.22Gi | 2.47Gi | 1.91Gi | 512Mi | 4.00Gi |

**Deployment: `rybbit`** (VPA: `goldilocks-rybbit`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| rybbit | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| rybbit | Memory | 309Mi | 215Mi | 400Mi | 309Mi | N/A | N/A |

**Deployment: `rybbit-client`** (VPA: `goldilocks-rybbit-client`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| rybbit-client | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| rybbit-client | Memory | 175Mi | 174Mi | 226Mi | 175Mi | N/A | N/A |

### send

**Deployment: `send`** (VPA: `goldilocks-send`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| send | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| send | Memory | 100Mi | 100Mi | 116Mi | 100Mi | N/A | N/A |

### servarr

**Deployment: `flaresolverr`** (VPA: `goldilocks-flaresolverr`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| flaresolverr | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| flaresolverr | Memory | 641Mi | 308Mi | 830Mi | 641Mi | N/A | N/A |

**Deployment: `listenarr`** (VPA: `goldilocks-listenarr`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| listenarr | CPU | 15m | 15m | 15m | 15m | 25m | 1.0 |
| listenarr | Memory | 729Mi | 523Mi | 944Mi | 729Mi | 256Mi | 1.00Gi |

**Deployment: `prowlarr`** (VPA: `goldilocks-prowlarr`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| prowlarr | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| prowlarr | Memory | 259Mi | 259Mi | 336Mi | 259Mi | N/A | N/A |

**Deployment: `qbittorrent`** (VPA: `goldilocks-qbittorrent`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| qbittorrent | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| qbittorrent | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

### shadowsocks

**Deployment: `shadowsocks`** (VPA: `goldilocks-shadowsocks`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| shadowsocks | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| shadowsocks | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

### speedtest

**Deployment: `speedtest`** (VPA: `goldilocks-speedtest`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| speedtest | CPU | 182m | 22m | 418m | 182m | 50m | 500m |
| speedtest | Memory | 309Mi | 259Mi | 547Mi | 309Mi | 128Mi | 512Mi |

### stirling-pdf

**Deployment: `stirling-pdf`** (VPA: `goldilocks-stirling-pdf`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| stirling-pdf | CPU | 15m | 15m | 29m | 15m | 100m | 2.0 |
| stirling-pdf | Memory | 1.09Gi | 728Mi | 1.41Gi | 1.09Gi | 256Mi | 1.00Gi |

### tandoor

**Deployment: `tandoor`** (VPA: `goldilocks-tandoor`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| recipes | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| recipes | Memory | 991Mi | 308Mi | 1.25Gi | 991Mi | N/A | N/A |

### technitium

**Deployment: `technitium`** (VPA: `goldilocks-technitium`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| technitium | CPU | 15m | 15m | 15m | 15m | 100m | 500m |
| technitium | Memory | 283Mi | 259Mi | 367Mi | 283Mi | 128Mi | 512Mi |

**Deployment: `technitium-secondary`** (VPA: `goldilocks-technitium-secondary`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| technitium | CPU | 15m | 15m | 49m | 15m | 100m | 500m |
| technitium | Memory | 175Mi | 104Mi | 376Mi | 175Mi | 128Mi | 512Mi |

**Job: `technitium-secondary-setup`** (VPA: `goldilocks-technitium-secondary-setup`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| setup | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| setup | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

### tigera-operator

**Deployment: `tigera-operator`** (VPA: `goldilocks-tigera-operator`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| tigera-operator | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| tigera-operator | Memory | 175Mi | 174Mi | 226Mi | 175Mi | N/A | N/A |

### tor-proxy

**Deployment: `tor-proxy`** (VPA: `goldilocks-tor-proxy`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| tor-proxy | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| tor-proxy | Memory | 121Mi | 100Mi | 157Mi | 121Mi | N/A | N/A |

### trading-bot

**Job: `trading-bot-db-init`** (VPA: `goldilocks-trading-bot-db-init`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| db-init | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| db-init | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

**Deployment: `trading-bot-frontend`** (VPA: `goldilocks-trading-bot-frontend`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| api-gateway | CPU | 11m | 10m | 23m | 11m | 50m | 1.0 |
| api-gateway | Memory | 237Mi | 194Mi | 511Mi | 237Mi | 128Mi | 512Mi |
| dashboard | CPU | 11m | 10m | 14m | 11m | 10m | 200m |
| dashboard | Memory | 50Mi | 50Mi | 50Mi | 50Mi | 32Mi | 128Mi |

**Job: `trading-bot-migrations`** (VPA: `goldilocks-trading-bot-migrations`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| migrations | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| migrations | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

**Deployment: `trading-bot-workers`** (VPA: `goldilocks-trading-bot-workers`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| learning-engine | CPU | 11m | 10m | 14m | 11m | 10m | 500m |
| learning-engine | Memory | 89Mi | 89Mi | 116Mi | 89Mi | 64Mi | 256Mi |
| market-data | CPU | 11m | 10m | 14m | 11m | 10m | 500m |
| market-data | Memory | 138Mi | 105Mi | 180Mi | 138Mi | 64Mi | 256Mi |
| news-fetcher | CPU | 11m | 10m | 14m | 11m | 10m | 500m |
| news-fetcher | Memory | 105Mi | 75Mi | 137Mi | 105Mi | 64Mi | 256Mi |
| sentiment-analyzer | CPU | 11m | 10m | 14m | 11m | 100m | 2.0 |
| sentiment-analyzer | Memory | 1.81Gi | 1.71Gi | 2.35Gi | 1.81Gi | 512Mi | 2.00Gi |
| signal-generator | CPU | 11m | 10m | 14m | 11m | 10m | 500m |
| signal-generator | Memory | 175Mi | 89Mi | 228Mi | 175Mi | 64Mi | 256Mi |
| trade-executor | CPU | 11m | 10m | 14m | 11m | 10m | 500m |
| trade-executor | Memory | 138Mi | 138Mi | 180Mi | 138Mi | 64Mi | 256Mi |

### traefik

**Deployment: `auth-proxy`** (VPA: `goldilocks-auth-proxy`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| nginx | CPU | 15m | 15m | 64m | 15m | 5m | 50m |
| nginx | Memory | 100Mi | 100Mi | 100Mi | 100Mi | 16Mi | 32Mi |

**Deployment: `bot-block-proxy`** (VPA: `goldilocks-bot-block-proxy`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| nginx | CPU | 15m | 15m | 63m | 15m | 5m | 50m |
| nginx | Memory | 100Mi | 100Mi | 100Mi | 100Mi | 16Mi | 32Mi |

**Deployment: `traefik`** (VPA: `goldilocks-traefik`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| traefik | CPU | 49m | 15m | 98m | 49m | 100m | N/A |
| traefik | Memory | 194Mi | 105Mi | 298Mi | 194Mi | 128Mi | N/A |

### travel-blog

**Deployment: `travel-blog`** (VPA: `goldilocks-travel-blog`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| travel-blog | CPU | 15m | 15m | 15m | 15m | 250m | 500m |
| travel-blog | Memory | 100Mi | 100Mi | 100Mi | 100Mi | 50Mi | 512Mi |

### tuya-bridge

**Deployment: `tuya-bridge`** (VPA: `goldilocks-tuya-bridge`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| tuya-bridge | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| tuya-bridge | Memory | 156Mi | 138Mi | 196Mi | 156Mi | N/A | N/A |

### uptime-kuma

**Deployment: `uptime-kuma`** (VPA: `goldilocks-uptime-kuma`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| uptime-kuma | CPU | 49m | 34m | 82m | 49m | 50m | 200m |
| uptime-kuma | Memory | 237Mi | 121Mi | 341Mi | 237Mi | 64Mi | 256Mi |

### url

**Deployment: `shlink`** (VPA: `goldilocks-shlink`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| shlink | CPU | 15m | 15m | 15m | 15m | 25m | N/A |
| shlink | Memory | 454Mi | 422Mi | 597Mi | 454Mi | 128Mi | 512Mi |

**Deployment: `shlink-web`** (VPA: `goldilocks-shlink-web`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| shlink-web | CPU | 15m | 15m | 15m | 15m | 250m | 500m |
| shlink-web | Memory | 100Mi | 100Mi | 100Mi | 100Mi | 50Mi | 512Mi |

### vaultwarden

**Deployment: `vaultwarden`** (VPA: `goldilocks-vaultwarden`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| vaultwarden | CPU | 15m | 15m | 15m | 15m | 50m | 200m |
| vaultwarden | Memory | 105Mi | 105Mi | 156Mi | 105Mi | 64Mi | 256Mi |

### vpa

**Deployment: `goldilocks-controller`** (VPA: `goldilocks-goldilocks-controller`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| goldilocks | CPU | 63m | 15m | 141m | 63m | 25m | N/A |
| goldilocks | Memory | 105Mi | 100Mi | 135Mi | 105Mi | 256Mi | N/A |

**Deployment: `goldilocks-dashboard`** (VPA: `goldilocks-goldilocks-dashboard`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| goldilocks | CPU | 15m | 15m | 15m | 15m | 25m | N/A |
| goldilocks | Memory | 100Mi | 100Mi | 135Mi | 100Mi | 256Mi | N/A |

**Job: `vpa-admission-certgen`** (VPA: `goldilocks-vpa-admission-certgen`, mode: `Off`)

_No recommendations available (insufficient data)_

**Deployment: `vpa-admission-controller`** (VPA: `goldilocks-vpa-admission-controller`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| vpa | CPU | 15m | 15m | 15m | 15m | 50m | N/A |
| vpa | Memory | 100Mi | 100Mi | 115Mi | 100Mi | 200Mi | N/A |

**Deployment: `vpa-recommender`** (VPA: `goldilocks-vpa-recommender`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| vpa | CPU | 23m | 22m | 29m | 23m | 50m | N/A |
| vpa | Memory | 121Mi | 121Mi | 156Mi | 121Mi | 500Mi | N/A |

**Deployment: `vpa-updater`** (VPA: `goldilocks-vpa-updater`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| vpa | CPU | 15m | 15m | 15m | 15m | 50m | N/A |
| vpa | Memory | 105Mi | 100Mi | 135Mi | 105Mi | 500Mi | N/A |

### wealthfolio

**Deployment: `wealthfolio`** (VPA: `goldilocks-wealthfolio`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| wealthfolio | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| wealthfolio | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

### webhook-handler

**Deployment: `webhook-handler`** (VPA: `goldilocks-webhook-handler`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| webhook-handler | CPU | 15m | 15m | 15m | 15m | 250m | 500m |
| webhook-handler | Memory | 100Mi | 100Mi | 100Mi | 100Mi | 50Mi | 512Mi |

### website

**Deployment: `blog`** (VPA: `goldilocks-blog`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| blog | CPU | 11m | 10m | 13m | 11m | 250m | 500m |
| blog | Memory | 50Mi | 50Mi | 50Mi | 50Mi | 50Mi | 512Mi |
| nginx-exporter | CPU | 11m | 10m | 13m | 11m | N/A | N/A |
| nginx-exporter | Memory | 50Mi | 50Mi | 50Mi | 50Mi | N/A | N/A |

### whisper

**Deployment: `piper`** (VPA: `goldilocks-piper`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| piper | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| piper | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

**Deployment: `whisper`** (VPA: `goldilocks-whisper`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| whisper | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| whisper | Memory | 729Mi | 728Mi | 942Mi | 729Mi | N/A | N/A |

### wireguard

**Deployment: `wireguard`** (VPA: `goldilocks-wireguard`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| prometheus-exporter | CPU | 11m | 10m | 14m | 11m | N/A | N/A |
| prometheus-exporter | Memory | 50Mi | 50Mi | 50Mi | 50Mi | N/A | N/A |
| wireguard | CPU | 11m | 10m | 14m | 11m | N/A | N/A |
| wireguard | Memory | 50Mi | 50Mi | 50Mi | 50Mi | N/A | N/A |

### woodpecker

**StatefulSet: `woodpecker-agent`** (VPA: `goldilocks-woodpecker-agent`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| agent | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| agent | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

**Job: `woodpecker-db-init`** (VPA: `goldilocks-woodpecker-db-init`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| db-init | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| db-init | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

**StatefulSet: `woodpecker-server`** (VPA: `goldilocks-woodpecker-server`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| server | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| server | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

### xray

**Deployment: `xray`** (VPA: `goldilocks-xray`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| xray | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| xray | Memory | 100Mi | 100Mi | 100Mi | 100Mi | N/A | N/A |

### ytdlp

**Deployment: `yt-highlights`** (VPA: `goldilocks-yt-highlights`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| yt-highlights | CPU | 15m | 15m | 15m | 15m | N/A | N/A |
| yt-highlights | Memory | 237Mi | 237Mi | 306Mi | 237Mi | N/A | N/A |

**Deployment: `ytdlp`** (VPA: `goldilocks-ytdlp`, mode: `Off`)

| Container | Metric | Target | Lower Bound | Upper Bound | Uncapped Target | Current Request | Current Limit |
|-----------|--------|--------|-------------|-------------|-----------------|-----------------|---------------|
| ytdlp | CPU | 15m | 15m | 15m | 15m | 25m | 500m |
| ytdlp | Memory | 283Mi | 215Mi | 367Mi | 283Mi | 128Mi | 512Mi |

---

## Namespaces Without VPA Objects

These namespaces have no Goldilocks VPA objects:

- `gadget`
- `kube-node-lease`
- `kube-public`
- `reverse-proxy`

## VPA Objects Without Recommendations

These VPA objects exist but have no container recommendations (likely insufficient usage data):

- `actualbudget/goldilocks-bank-sync-anca`
- `actualbudget/goldilocks-bank-sync-emo`
- `actualbudget/goldilocks-bank-sync-viktor`
- `dbaas/goldilocks-mysql-backup`
- `dbaas/goldilocks-postgresql-backup`
- `default/goldilocks-backup-etcd`
- `default/goldilocks-cleanup-failed-pods`
- `default/goldilocks-monitor-prometheus`
- `ebook2audiobook/goldilocks-audiblez`
- `ebook2audiobook/goldilocks-ebook2audiobook`
- `immich/goldilocks-postgresql-backup`
- `matrix/goldilocks-matrix`
- `nextcloud/goldilocks-nextcloud-backup`
- `osm-routing/goldilocks-otp`
- `poison-fountain/goldilocks-poison-fountain-fetcher`
- `redis/goldilocks-redis-backup`
- `reloader/goldilocks-reloader-reloader`
- `vpa/goldilocks-vpa-admission-certgen`
