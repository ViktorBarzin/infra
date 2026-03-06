# Kubernetes Cluster Resource Audit - Live Metrics

**Collected**: 2026-03-01
**Cluster**: 5 nodes (k8s-master + k8s-node1-4), Kubernetes v1.34.2

---

## EXECUTIVE SUMMARY

### Critical Issues

#### OOMKilled Pods
| Namespace | Pod | Status |
|-----------|-----|--------|
| dbaas | mysql-cluster-0 | OOMKilled (last state) |

#### CrashLoopBackOff / ImagePullBackOff Pods
| Namespace | Pod | Status |
|-----------|-----|--------|
| vpa | vpa-admission-certgen-kdvqj | ImagePullBackOff |

#### Pods with NO Resource Limits (unbounded)
These pods have `<none>` for CPU and/or memory limits -- they can consume unlimited node resources:

| Namespace | Pod | Container | CPU Limit | Mem Limit |
|-----------|-----|-----------|-----------|-----------|
| calico-apiserver | calico-apiserver-*-bq6zp | calico-apiserver | <none> | <none> |
| calico-apiserver | calico-apiserver-*-q794h | calico-apiserver | <none> | <none> |
| calico-system | calico-kube-controllers-* | calico-kube-controllers | <none> | <none> |
| calico-system | calico-node-* (5 pods) | calico-node | <none> | <none> |
| calico-system | calico-typha-*-9wr7z | calico-typha | <none> | <none> |
| calico-system | calico-typha-*-hw8wt | calico-typha | <none> | <none> |
| calico-system | calico-typha-*-z69vx | calico-typha | <none> | <none> |
| calico-system | csi-node-driver-* (5 pods) | calico-csi, csi-node-driver-registrar | <none> | <none> |
| kube-system | etcd-k8s-master | etcd | <none> | <none> |
| kube-system | kube-apiserver-k8s-master | kube-apiserver | <none> | <none> |
| kube-system | kube-controller-manager-k8s-master | kube-controller-manager | <none> | <none> |
| kube-system | kube-proxy-* (5 pods) | kube-proxy | <none> | <none> |
| kube-system | kube-scheduler-k8s-master | kube-scheduler | <none> | <none> |
| kyverno | kyverno-admission-controller-* (2 pods) | kyverno | <none> (CPU) | 768Mi |
| kyverno | kyverno-background-controller-* | controller | <none> (CPU) | 128Mi |
| kyverno | kyverno-cleanup-controller-* | controller | <none> (CPU) | 128Mi |
| kyverno | kyverno-reports-controller-* | controller | <none> (CPU) | 128Mi |
| metallb-system | controller-* | controller | <none> | <none> |
| metallb-system | speaker-dn9bk | speaker | <none> | <none> |
| metallb-system | speaker-mnpsl | speaker | <none> | <none> |
| metallb-system | speaker-pl8dz | speaker | <none> | <none> |
| nvidia | nvidia-driver-daemonset-x2r6b | nvidia-driver-ctr | <none> | <none> |

**Note**: kube-system and calico-system pods without limits are standard for control-plane components. The NVIDIA driver daemonset is also expected. MetalLB pods without limits should be monitored.

#### Pods Near or Exceeding Memory Limits (>75% utilization)

| Namespace | Pod | Current Usage | Memory Limit | % Used |
|-----------|-----|--------------|--------------|--------|
| dbaas | mysql-cluster-0 | 1845Mi | 2Gi (sidecar:512Mi + mysql:2Gi) | ~90% of mysql container |
| dbaas | mysql-cluster-2 | 1212Mi | 2Gi (sidecar:512Mi + mysql:2Gi) | ~59% combined |
| dbaas | mysql-cluster-1 | 1083Mi | 2Gi (sidecar:512Mi + mysql:2Gi) | ~53% combined |
| dashy | dashy-* | 1048Mi | 4Gi | 26% but NOTE: 490m CPU near 500m limit (98%) |
| onlyoffice | onlyoffice-document-server-* | 1007Mi | 4Gi | 25% |
| stirling-pdf | stirling-pdf-* | 902Mi | 4Gi | 23% |
| trading-bot | trading-bot-workers-* | 1901Mi | 2Gi (sentiment-analyzer) | ~95% of largest container |
| authentik | goauthentik-server-*-x68p7 | 593Mi | 1Gi | 58% |
| authentik | goauthentik-server-*-4bjll | 583Mi | 1Gi | 57% |
| authentik | goauthentik-server-*-z68g8 | 548Mi | 1Gi | 54% |
| authentik | goauthentik-worker-*-klk6z | 551Mi | 1Gi | 54% |
| servarr | flaresolverr-* | 148Mi | 256Mi | 58% |
| speedtest | speedtest-* | 147Mi | ~1.2Gi | 12% |
| cnpg-system | cnpg-cloudnative-pg-* | 72Mi | 256Mi | 28% |
| mailserver | mailserver-* | 183Mi | 256Mi+256Mi | 36% per container |
| vpa | vpa-recommender-* | 74Mi | 512Mi | 14% (but 500Mi req = nearly full request!) |

#### Pods with CPU Near Limit (potential throttling)

| Namespace | Pod | Current CPU | CPU Limit | % Used |
|-----------|-----|------------|-----------|--------|
| dashy | dashy-* | 490m | 500m | **98%** -- actively throttling |
| stirling-pdf | stirling-pdf-* | 299m | 300m | **99.7%** -- actively throttling |
| frigate | frigate-* | 860m | 8000m | 11% |
| crowdsec | crowdsec-agent-rkvf2 | 13m | 500m | 3% (but req=limit=500m) |
| redis | redis-node-0 | 44m | 500m (redis) + 200m (sentinel) | 6% |
| redis | redis-node-1 | 43m | 1260m (redis) + 140m (sentinel) | 3% |

---

## NODE-LEVEL RESOURCE USAGE

| Node | CPU (cores) | CPU % | Memory | Memory % |
|------|-------------|-------|--------|----------|
| k8s-master | 805m | 10% | 5132Mi | 65% |
| k8s-node1 | 1002m | 6% | 9192Mi | 57% |
| k8s-node2 | 894m | 11% | 11517Mi | 48% |
| k8s-node3 | 781m | 9% | 13103Mi | 54% |
| k8s-node4 | 1333m | 16% | 13122Mi | 54% |
| **TOTAL** | **4815m** | **~10%** | **52066Mi** | **~55%** |

**Observations**:
- Memory is the tighter resource (~55% cluster-wide), CPU is abundant (~10%)
- k8s-master at 65% memory -- highest, but still has headroom
- k8s-node3 and k8s-node4 carry the most memory workloads (~13Gi each)

---

## POD RESOURCE USAGE BY NAMESPACE (sorted by total memory)

### Top 20 Memory Consumers

| Rank | Namespace/Pod | CPU | Memory | Mem Limit |
|------|--------------|-----|--------|-----------|
| 1 | frigate/frigate | 860m | 3835Mi | 16Gi |
| 2 | kube-system/kube-apiserver | 376m | 2531Mi | <none> |
| 3 | monitoring/prometheus-server | 36m | 1912Mi | 4Gi |
| 4 | trading-bot/trading-bot-workers | 7m | 1901Mi | 2Gi (largest) |
| 5 | dbaas/mysql-cluster-0 | 62m | 1845Mi | 2Gi (mysql) |
| 6 | monitoring/loki-0 | 95m | 1335Mi | ~2.9Gi |
| 7 | immich/immich-machine-learning | 8m | 1215Mi | 16Gi |
| 8 | dbaas/mysql-cluster-2 | 32m | 1212Mi | 2Gi (mysql) |
| 9 | nvidia/nvidia-driver-daemonset | 0m | 1168Mi | <none> |
| 10 | dbaas/mysql-cluster-1 | 40m | 1083Mi | 2Gi (mysql) |
| 11 | dashy/dashy | 490m | 1048Mi | 4Gi |
| 12 | onlyoffice/onlyoffice-document-server | 3m | 1007Mi | 4Gi |
| 13 | stirling-pdf/stirling-pdf | 299m | 902Mi | 4Gi |
| 14 | tandoor/tandoor | 1m | 754Mi | ~3.1Gi |
| 15 | paperless-ngx/paperless-ngx | 4m | 691Mi | ~3.7Gi |
| 16 | linkwarden/linkwarden | 8m | 682Mi | ~3.3Gi |
| 17 | ollama/ollama-ui | 2m | 658Mi | ~5.8Gi |
| 18 | whisper/whisper | 1m | 628Mi | ~5.8Gi |
| 19 | realestate-crawler/celery | 2m | 608Mi | 2Gi |
| 20 | authentik/goauthentik-server (x3) | ~17m each | ~575Mi each | 1Gi |

### Top 10 CPU Consumers

| Rank | Namespace/Pod | CPU | CPU Limit |
|------|--------------|-----|-----------|
| 1 | frigate/frigate | 860m | 8000m |
| 2 | dashy/dashy | 490m | 500m |
| 3 | kube-system/kube-apiserver | 376m | <none> |
| 4 | stirling-pdf/stirling-pdf | 299m | 300m |
| 5 | kube-system/etcd | 216m | <none> |
| 6 | monitoring/loki-0 | 95m | 504m |
| 7 | authentik/goauthentik-worker-c5zfs | 81m | 2000m |
| 8 | authentik/goauthentik-worker-b5wzk | 62m | 2000m |
| 9 | dbaas/mysql-cluster-0 | 62m | 2000m |
| 10 | calico-system/calico-node-wllsb | 49m | <none> |

---

## DETAILED NAMESPACE BREAKDOWN

### actualbudget
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| actualbudget-anca | 1m | 42Mi | 25m/250m | 64Mi/256Mi |
| actualbudget-emo | 1m | 40Mi | 25m/250m | 64Mi/256Mi |
| actualbudget-http-api-anca | 1m | 26Mi | 25m/250m | 64Mi/256Mi |
| actualbudget-http-api-emo | 0m | 26Mi | 25m/250m | 64Mi/256Mi |
| actualbudget-http-api-viktor | 1m | 29Mi | 25m/250m | 64Mi/256Mi |
| actualbudget-viktor | 1m | 56Mi | 25m/250m | 64Mi/256Mi |
**Quota**: 150m/4000m CPU used, 384Mi/4Gi mem used, 6/30 pods

### affine
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| affine | 4m | 174Mi | 35m/700m | ~237Mi/~1.9Gi |
**Quota**: 35m/2000m CPU, ~237Mi/2Gi mem, 1/20 pods

### aiostreams
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| aiostreams | 1m | 215Mi | 50m/500m | 256Mi/768Mi |

### atuin
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| atuin | 1m | 2Mi | 50m/500m | 64Mi/256Mi |

### audiobookshelf
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| audiobookshelf | 1m | 55Mi | 15m/150m | ~100Mi/400Mi |

### authentik
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| ak-outpost-embedded | 6m | 18Mi | 50m/500m | 64Mi/512Mi |
| goauthentik-server (x3) | 14-21m | 548-593Mi | 100m/2000m | 512Mi/1Gi |
| goauthentik-worker (x3) | 40-81m | 420-551Mi | 50-100m/1-2000m | 384Mi-600Mi/1-1.6Gi |
| pgbouncer (x3) | 1-2m | 2Mi | 15-50m/150-500m | ~100Mi/512-800Mi |
**Quota**: 680m/16000m CPU, ~3.3Gi/16Gi mem, 10/50 pods

### calibre
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| annas-archive-stacks | 1m | 60Mi | 25m/250m | 64Mi/256Mi |
| calibre-web-automated | 1m | 196Mi | 23m/460m | ~640Mi/~2.6Gi |

### changedetection
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| changedetection (2 containers) | 6m | 111Mi | 25m+25m/250m+250m | 64Mi+64Mi/256Mi+256Mi |

### cloudflared
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| cloudflared (x3) | 3-9m | 31-59Mi | 50m/500m | 64Mi/512Mi |

### crowdsec
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| crowdsec-agent (x3) | 3-13m | 43-48Mi | 500m/500m | 250Mi/250Mi |
| crowdsec-lapi (x3) | 1m | 30-34Mi | 23m/23m | ~121Mi/~121Mi |
| crowdsec-web | 2m | 46Mi | 50m/500m | 64Mi/512Mi |
**Note**: crowdsec-agent has CPU req=limit=500m (Guaranteed QoS). Same for memory at 250Mi.

### dashy
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| dashy | **490m** | 1048Mi | 15m/**500m** | 512Mi/4Gi |
**WARNING**: CPU at 98% of limit -- actively being throttled!

### dawarich
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| dawarich | 1m | 438Mi | 15m/150m | ~600Mi/~2.4Gi |

### dbaas
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| mysql-cluster-0 | 62m | 1845Mi | 50m+250m/500m+2000m | 64Mi+1Gi/512Mi+2Gi |
| mysql-cluster-1 | 40m | 1083Mi | 50m+250m/500m+2000m | 64Mi+1Gi/512Mi+2Gi |
| mysql-cluster-2 | 32m | 1212Mi | 50m+250m/500m+2000m | 64Mi+1Gi/512Mi+2Gi |
| pg-cluster-1 | 22m | 335Mi | 250m/2000m | 512Mi/4Gi |
| pg-cluster-2 | 11m | 155Mi | 250m/2000m | 512Mi/4Gi |
| pgadmin | 1m | 265Mi | 50m/500m | 64Mi/512Mi |
| phpmyadmin | 1m | 46Mi | 50m/500m | 64Mi/512Mi |
**WARNING**: mysql-cluster-0 was OOMKilled previously. Currently at 1845Mi with 2Gi limit on mysql container (~90%).
**Quota**: 1500m/8000m CPU, 4416Mi/12Gi mem, 7/30 pods

### echo
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| echo (x5) | 0-1m | 19-30Mi | 15-25m/150-250m | 64Mi-100Mi/256-400Mi |

### forgejo
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| forgejo | 1m | 170Mi | 15m/500m | ~215Mi/~1.7Gi |

### freedify
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| music-emo | 2m | 68Mi | 100m/500m | 256Mi/512Mi |
| music-viktor | 2m | 57Mi | 100m/500m | 256Mi/512Mi |

### frigate
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| frigate | 860m | 3835Mi | 800m/8000m | 2Gi/16Gi |
**Note**: Highest memory consumer in the cluster. GPU tier (2-gpu).

### headscale
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| headscale (2 containers) | 1m | 65Mi | 50m+25m/200m+100m | 64Mi+32Mi/256Mi+128Mi |

### homepage
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| homepage | 1m | 86Mi | 15m/150m | ~121Mi/~484Mi |

### immich
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| immich-frame | 1m | 30Mi | 15m/150m | ~105Mi/~838Mi |
| immich-machine-learning | 8m | 1215Mi | 15m/150m | 2Gi/16Gi |
| immich-postgresql | 1m | 268Mi | 15m/150m | ~990Mi/~7.9Gi |
| immich-server | 3m | 404Mi | 800m/8000m | ~990Mi/~7.9Gi |
**Quota**: 845m/8000m CPU, ~4.1Gi/8Gi mem, 4/40 pods. Note: mem at ~51% of quota.

### kms
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| kms | 0m | 0Mi | 15m/15m | ~100Mi/1Gi |
| kms-web-page | 0m | 10Mi | 500m/500m | 512Mi/512Mi |
**Note**: kms-web-page has req=limit (Guaranteed QoS) at 500m CPU and 512Mi, but uses 0m/10Mi.

### linkwarden
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| linkwarden | 8m | 682Mi | 15m/150m | ~826Mi/~3.3Gi |

### mailserver
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| mailserver (2 containers) | 9m | 183Mi | 25m+25m/250m+250m | 64Mi+64Mi/256Mi+256Mi |
| roundcubemail | 1m | 44Mi | 25m/250m | 64Mi/256Mi |

### meshcentral
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| meshcentral | 1m | 127Mi | 15m/300m | ~283Mi/~850Mi |

### monitoring
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| alloy (x3, DaemonSet) | 44-47m | 182-201Mi | 63m+11m/252m+550m | ~422Mi+50Mi/~845Mi+512Mi |
| caretta (x4, DaemonSet) | 2-4m | 250-267Mi | 15m/225m | ~422Mi/~2.5Gi |
| goflow2 | 11m | 28Mi | 15m/60m | ~100Mi/400Mi |
| grafana (x3) | 18m | 232-235Mi | 11m+11m+35m/110m+110m+350m | multi-container |
| idrac-redfish-exporter | 3m | 9Mi | 15m/150m | ~100Mi/800Mi |
| loki-0 (2 containers) | 95m | 1335Mi | 126m+11m/504m+110m | ~1.9Gi+~121Mi/~2.9Gi+~968Mi |
| node-exporter (x5) | 1m | 9-24Mi | 15m/150m | ~100Mi/800Mi |
| prometheus-alertmanager | 2m | 24Mi | 15m/150m | ~100Mi/800Mi |
| prometheus-kube-state-metrics | 3m | 33Mi | 15m/150m | ~100Mi/800Mi |
| prometheus-pushgateway | 1m | 18Mi | 15m/150m | ~100Mi/800Mi |
| prometheus-server (2 containers) | 36m | 1912Mi | 11m+93m/110m+930m | 50Mi+512Mi/400Mi+4Gi |
| proxmox-exporter | 1m | 41Mi | 23m/230m | ~100Mi/800Mi |
| snmp-exporter | 2m | 14Mi | 15m/150m | ~100Mi/800Mi |
| sysctl-inotify (x5) | 0m | 0Mi | 15m/15m | ~100Mi/~100Mi |
**Quota**: 1177m/16000m CPU, ~9Gi/16Gi mem, 32/100 pods

### mysql-operator
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| mysql-operator | 4m | 254Mi | 23m/230m | ~309Mi/~1.2Gi |

### n8n
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| n8n | 2m | 425Mi | 15m/150m | ~524Mi/~2.1Gi |

### netbox
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| netbox | 1m | 480Mi | 50m/2000m | 512Mi/4Gi |

### nextcloud
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| nextcloud (2 containers) | 9m | 234Mi | 100m+11m/16000m+110m | ~1.3Gi+~121Mi/~8Gi+~484Mi |
| whiteboard | 1m | 62Mi | 25m/250m | 64Mi/256Mi |
**Quota**: 136m/4000m CPU, ~1.5Gi/8Gi mem, 2/10 pods

### nvidia
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| gpu-feature-discovery | 1m | 76Mi | 100m+100m/1+1 | 256Mi+256Mi/2Gi+2Gi |
| gpu-operator | 14m | 63Mi | 200m/500m | 100Mi/350Mi |
| gpu-pod-exporter | 2m | 50Mi | 50m/200m | 128Mi/256Mi |
| nvidia-container-toolkit | 1m | 27Mi | 100m/1000m | 256Mi/2Gi |
| nvidia-dcgm-exporter | 17m | 538Mi | 100m/1000m | 256Mi/2Gi |
| nvidia-device-plugin | 1m | 47Mi | 100m+100m/1+1 | 256Mi+256Mi/2Gi+2Gi |
| nvidia-driver-daemonset | 0m | 1168Mi | <none> | <none> |
| nvidia-exporter | 1m | 138Mi | 15m/150m | ~121Mi/~968Mi |
| nfd-gc | 1m | 9Mi | 15m/1500m | ~100Mi/800Mi |
| nfd-master | 1m | 27Mi | 100m/4000m | 128Mi/4Gi |
| nfd-worker (x5) | 1m | 14-18Mi | 15m/3000m | ~100Mi/800Mi |
| nvidia-operator-validator | 0m | 1Mi | 100m/1000m | 256Mi/2Gi |

### ollama
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| ollama | 1m | 11Mi | 500m/4000m | 4Gi/12Gi |
| ollama-ui | 2m | 658Mi | 15m/150m | ~729Mi/~5.8Gi |
**Note**: ollama pod at only 11Mi but reserves 4Gi -- GPU workload likely using VRAM instead.

### onlyoffice
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| onlyoffice-document-server | 3m | 1007Mi | 250m/8000m | 512Mi/4Gi |
**Quota**: 250m/4000m CPU, 512Mi/4Gi mem, 1/10 pods

### openclaw
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| openclaw (2 containers) | 2m | 447Mi | 100m+25m/2000m+500m | 512Mi+64Mi/2Gi+256Mi |

### osm-routing
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| osrm-bicycle | 0m | 366Mi | 15m/250m | ~454Mi/~909Mi |
| osrm-foot | 0m | 359Mi | 15m/150m | ~454Mi/~1.8Gi |

### paperless-ngx
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| paperless-ngx | 4m | 691Mi | 49m/980m | ~933Mi/~3.7Gi |

### realestate-crawler
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| realestate-crawler-api (x2) | 2m | 133-134Mi | 15m/600m | ~194Mi/~1.6Gi |
| realestate-crawler-celery | 2m | 608Mi | 100m/2000m | 512Mi/2Gi |
| realestate-crawler-celery-beat | 0m | 107Mi | 15m/300m | ~175Mi/~699Mi |
| realestate-crawler-ui (x2) | 0m | 7-8Mi | 15-25m/150-250m | 64-100Mi/256-400Mi |

### redis
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| redis-node-0 (redis+sentinel) | 44m | 47Mi | 50m+50m/500m+200m | 64Mi+64Mi/256Mi+128Mi |
| redis-node-1 (redis+sentinel) | 43m | 25Mi | 126m+35m/1260m+140m | ~50Mi+~50Mi/200Mi+100Mi |

### resume
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| printer | 3m | 109Mi | 15m/300m | 1Gi/4Gi |
| resume | 1m | 116Mi | 15m/300m | ~215Mi/~645Mi |

### rybbit
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| rybbit | 2m | 185Mi | 15m/150m | ~215Mi/~860Mi |
| rybbit-client | 1m | 89Mi | 25m/250m | 64Mi/256Mi |
**Note**: rybbit-client at 89Mi with 256Mi limit (35%).

### servarr
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| flaresolverr | 1m | 148Mi | 25m/250m | 64Mi/256Mi |
| listenarr | 2m | 383Mi | 15m/600m | ~640Mi/~2.6Gi |
| prowlarr | 1m | 149Mi | 15m/150m | ~260Mi/~1Gi |
| qbittorrent | 1m | 29Mi | 25m/250m | 64Mi/256Mi |
**WARNING**: flaresolverr at 148Mi / 256Mi = 58% of mem limit.

### speedtest
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| speedtest | 1m | 147Mi | 200m/2000m | ~309Mi/~1.2Gi |

### stirling-pdf
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| stirling-pdf | **299m** | 902Mi | 15m/**300m** | 1Gi/4Gi |
**WARNING**: CPU at 99.7% of limit -- actively being throttled!

### tandoor
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| tandoor | 1m | 754Mi | 15m/150m | ~776Mi/~3.1Gi |

### technitium
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| technitium | 1m | 184Mi | 100m/500m | 128Mi/512Mi |
| technitium-secondary | 9m | 123Mi | 100m/500m | 128Mi/512Mi |

### trading-bot
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| trading-bot-frontend (2 containers) | 2m | 174Mi | 10m+50m/200m+1000m | 32Mi+128Mi/128Mi+512Mi |
| trading-bot-workers (6 containers) | 7m | 1901Mi | 10m+100m+10m+10m+10m+10m/500m+2000m+500m+500m+500m+500m | 64Mi*5+512Mi/256Mi*5+2Gi |
**WARNING**: trading-bot-workers at 1901Mi. The sentiment-analyzer container has 2Gi limit, possibly near OOM.

### traefik
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| auth-proxy (x2) | 1m | 7Mi | 5m/50m | 16Mi/32Mi |
| bot-block-proxy (x2) | 1m | 7Mi | 5m/50m | 16Mi/32Mi |
| traefik (x3) | 4-14m | 81-120Mi | 100m/500m | 128Mi/512Mi |

### uptime-kuma
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| uptime-kuma | 23m | 163Mi | 49m/196m | ~237Mi/~947Mi |

### vpa
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| goldilocks-controller | 7m | 30Mi | 49m/980m | ~105Mi/~209Mi |
| goldilocks-dashboard | 1m | 8Mi | 15m/300m | ~105Mi/~209Mi |
| vpa-admission-certgen | N/A | N/A | 50m/500m | 64Mi/512Mi |
| vpa-admission-controller | 3m | 48Mi | 50m/500m | 200Mi/512Mi |
| vpa-recommender | 13m | 74Mi | 50m/500m | 500Mi/512Mi |
| vpa-updater | 2m | 68Mi | 50m/500m | 500Mi/512Mi |
**WARNING**: vpa-admission-certgen in ImagePullBackOff.

### whisper
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| piper | 0m | 32Mi | 100m/1000m | 256Mi/2Gi |
| whisper | 1m | 628Mi | 15m/150m | ~729Mi/~5.8Gi |

### wireguard
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| wireguard (2 containers) | 1m | 2Mi | 50m+50m/500m+500m | 64Mi+64Mi/512Mi+512Mi |

### woodpecker
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| woodpecker-agent-0 | 1m | 17Mi | 15m/150m | ~100Mi/400Mi |
| woodpecker-agent-1 | 1m | 28Mi | 25m/250m | 64Mi/256Mi |
| woodpecker-server-0 | 4m | 32Mi | 25m/250m | 64Mi/256Mi |

### website
| Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----|----------|----------|-------------|-------------|
| blog (x3, 2 containers each) | 0-1m | 17-19Mi | 11m+11m/22m+110m | ~50Mi+~50Mi/512Mi+200Mi |

### Other Small Namespaces
| Namespace | Pod | CPU Used | Mem Used | CPU Req/Lim | Mem Req/Lim |
|-----------|-----|----------|----------|-------------|-------------|
| city-guesser | city-guesser | 1m | 23Mi | 250m/500m | 50Mi/512Mi |
| coturn | coturn | 1m | 7Mi | 15m/150m | ~100Mi/400Mi |
| cyberchef | cyberchef | 0m | 8Mi | 15m/150m | ~100Mi/400Mi |
| diun | diun | 1m | 24Mi | 15m/150m | ~100Mi/400Mi |
| excalidraw | excalidraw | 0m | 2Mi | 15m/150m | ~100Mi/400Mi |
| f1-stream | f1-stream | 7m | 53Mi | 50m/500m | 64Mi/256Mi |
| freshrss | freshrss | 1m | 56Mi | 25m/250m | 64Mi/256Mi |
| hackmd | hackmd | 2m | 82Mi | 15m/150m | ~138Mi/~552Mi |
| health | health | 2m | 101Mi | 100m/1000m | 256Mi/1Gi |
| isponsorblocktv | isponsorblocktv-vermont | 1m | 42Mi | 15m/150m | ~100Mi/400Mi |
| jsoncrack | jsoncrack | 0m | 7Mi | 15m/150m | ~100Mi/400Mi |
| k8s-portal | k8s-portal | 0m | 14Mi | 25m/250m | 64Mi/256Mi |
| navidrome | navidrome | 1m | 62Mi | 15m/150m | ~156Mi/~623Mi |
| ntfy | ntfy | 1m | 20Mi | 25m/250m | 64Mi/256Mi |
| owntracks | owntracks | 1m | 1Mi | 15m/150m | ~100Mi/400Mi |
| plotting-book | plotting-book | 0m | 22Mi | 50m/500m | 128Mi/512Mi |
| privatebin | privatebin | 1m | 46Mi | 15m/150m | ~100Mi/400Mi |
| send | send | 0m | 53Mi | 15m/150m | ~100Mi/400Mi |
| shadowsocks | shadowsocks | 1m | 0Mi | 15m/150m | ~100Mi/400Mi |
| tor-proxy | tor-proxy | 1m | 61Mi | 15m/150m | ~105Mi/~419Mi |
| vaultwarden | vaultwarden | 1m | 49Mi | 50m/200m | 64Mi/256Mi |
| wealthfolio | wealthfolio | 0m | 8Mi | 15m/150m | ~100Mi/400Mi |
| webhook-handler | webhook-handler | 1m | 8Mi | 15m/30m | ~100Mi/1Gi |
| xray | xray | 0m | 11Mi | 50m/500m | 64Mi/512Mi |

---

## LIMITRANGE DEFAULTS BY NAMESPACE

| Namespace | Default CPU | Default Mem | Max CPU | Max Mem | Tier |
|-----------|-------------|-------------|---------|---------|------|
| **GPU tier (2-gpu)** | | | | | |
| ebook2audiobook | 1 | 2Gi | 8 | 16Gi | 2-gpu |
| frigate | 1 | 2Gi | 8 | 16Gi | 2-gpu |
| immich | 1 | 2Gi | 8 | 16Gi | 2-gpu |
| nvidia | 1 | 2Gi | 8 | 16Gi | 2-gpu |
| ollama | 1 | 2Gi | 8 | 16Gi | 2-gpu |
| whisper | 1 | 2Gi | 8 | 16Gi | 2-gpu |
| **Core tier (0-core)** | | | | | |
| cloudflared | 500m | 512Mi | 4 | 8Gi | 0-core |
| headscale | 500m | 512Mi | 4 | 8Gi | 0-core |
| technitium | 500m | 512Mi | 4 | 8Gi | 0-core |
| traefik | 500m | 512Mi | 4 | 8Gi | 0-core |
| wireguard | 500m | 512Mi | 4 | 8Gi | 0-core |
| xray | 500m | 512Mi | 4 | 8Gi | 0-core |
| **Cluster tier (1-cluster)** | | | | | |
| authentik | 500m | 512Mi | 2 | 4Gi | 1-cluster |
| cnpg-system | 500m | 512Mi | 2 | 4Gi | 1-cluster |
| crowdsec | 500m | 512Mi | 2 | 4Gi | 1-cluster |
| dbaas | 500m | 512Mi | 2 | 4Gi | 1-cluster |
| metrics-server | 500m | 512Mi | 2 | 4Gi | 1-cluster |
| monitoring | 500m | 512Mi | 2 | 4Gi | 1-cluster |
| poison-fountain | 500m | 512Mi | 2 | 4Gi | 1-cluster |
| redis | 500m | 512Mi | 2 | 4Gi | 1-cluster |
| tuya-bridge | 500m | 512Mi | 2 | 4Gi | 1-cluster |
| uptime-kuma | 500m | 512Mi | 2 | 4Gi | 1-cluster |
| vpa | 500m | 512Mi | 2 | 4Gi | 1-cluster |
| **Edge tier (3-edge)** | | | | | |
| Most app namespaces | 250m | 256Mi | 2 | 4Gi | 3-edge |
| **Aux tier (4-aux)** | | | | | |
| Some app namespaces | 250m | 256Mi | 2 | 4Gi | 4-aux |
| **Custom LimitRanges** | | | | | |
| nextcloud | 250m | 256Mi | 16 | 8Gi | Custom |
| onlyoffice | 250m | 256Mi | 8 | 8Gi | Custom |
| **No tier** | | | | | |
| aiostreams | 250m | 256Mi | 1 | 2Gi | None |
| default | 250m | 256Mi | 1 | 2Gi | None |
| descheduler | 250m | 256Mi | 1 | 2Gi | None |
| gadget | 250m | 256Mi | 1 | 2Gi | None |
| kured | 250m | 256Mi | 1 | 2Gi | None |
| local-path-storage | 250m | 256Mi | 1 | 2Gi | None |
| mysql-operator | 250m | 256Mi | 1 | 2Gi | None |
| reverse-proxy | 250m | 256Mi | 1 | 2Gi | None |
| tigera-operator | 250m | 256Mi | 1 | 2Gi | None |

---

## RESOURCEQUOTA UTILIZATION (top consumers)

| Namespace | CPU Req Used/Hard | Mem Req Used/Hard | Pods Used/Hard | % Mem Req |
|-----------|-------------------|-------------------|----------------|-----------|
| monitoring | 1177m/16000m | ~9Gi/16Gi | 32/100 | ~56% |
| authentik | 680m/16000m | ~3.3Gi/16Gi | 10/50 | ~21% |
| crowdsec | 1619m/8000m | ~1.1Gi/8Gi | 7/30 | ~14% |
| dbaas | 1500m/8000m | 4416Mi/12Gi | 7/30 | ~36% |
| immich | 845m/8000m | ~4.1Gi/8Gi | 4/40 | ~51% |
| ollama | 515m/8000m | ~4.7Gi/8Gi | 2/40 | ~59% |
| nextcloud | 136m/4000m | ~1.5Gi/8Gi | 2/10 | ~19% |
| rybbit | 140m/2000m | ~791Mi/2Gi | 3/20 | ~39% |

---

## ACTION ITEMS

### Immediate (potential service impact)
1. **dashy** -- CPU throttled at 98% (490m/500m). Increase CPU limit or investigate high CPU usage.
2. **stirling-pdf** -- CPU throttled at 99.7% (299m/300m). Increase CPU limit.
3. **dbaas/mysql-cluster-0** -- Previously OOMKilled. Currently at ~1845Mi with 2Gi limit on mysql container (~90%). Monitor closely or increase limit.
4. **vpa/vpa-admission-certgen** -- ImagePullBackOff. Fix image reference.
5. **trading-bot-workers** -- 1901Mi across 6 containers, sentiment-analyzer at 2Gi limit. Verify not OOMing.

### Medium Priority (resource waste or risk)
6. **kms/kms-web-page** -- Guaranteed QoS at 500m CPU / 512Mi, but only uses 0m/10Mi. Massive overprovisioning.
7. **ollama/ollama** -- Requests 4Gi memory but uses 11Mi (GPU model in VRAM). If not using CPU memory, reduce request.
8. **resume/printer** -- Requests 1Gi memory but uses 109Mi. Consider reducing.
9. **nvidia-driver-daemonset** -- No limits set, using 1168Mi. Standard for driver but worth noting.
10. **servarr/flaresolverr** -- At 58% memory (148Mi/256Mi). Trending toward limit.

### Low Priority (optimization opportunities)
11. Multiple pods in the monitoring namespace have generous limits but low actual usage (node-exporters at 9-24Mi with 800Mi limits).
12. crowdsec-agent pods have Guaranteed QoS (req=limit) at 500m/250Mi but use only 3-13m CPU and 43-48Mi memory.
13. Many edge-tier pods using <10% of their memory limits -- VPA recommendations could help right-size.
