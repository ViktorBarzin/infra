# Resource Right-Sizing Plan

## Methodology
- **Conservative**: limits = max(VPA upper bound * 2, current live usage * 2, minimum sane value)
- **Requests**: VPA target or current usage, whichever is higher
- **Floor values**: 10m CPU req, 25m CPU lim, 32Mi mem req, 64Mi mem lim (nothing goes below these)
- **GPU containers**: keep nvidia.com/gpu, add CPU/mem based on VPA data
- **Ollama special case**: remove CPU/mem limits entirely (keep only GPU + minimal requests)

## Wave 1: CRITICAL FIXES (actively broken)

### dashy — CPU throttled at 98% (490m/500m), mem needs 2.36Gi
- File: stacks/dashy/main.tf
- VPA target: 15m CPU, 2.36Gi mem | Upper: 15m CPU, 3.23Gi mem
- Live: 490m CPU, 1048Mi mem
- **New**: req 50m/512Mi, lim 2/4Gi

### stirling-pdf — CPU throttled at 99.7% (299m/300m)
- File: stacks/stirling-pdf/main.tf
- VPA target: 29m CPU, 1.41Gi mem | Upper: 29m CPU, 1.41Gi mem
- Live: 299m CPU, 902Mi mem
- **New**: req 100m/512Mi, lim 2/2Gi

### MySQL cluster — OOMKilled, 1845Mi with 2Gi limit
- File: stacks/platform/modules/dbaas/main.tf
- Already bumped to 3Gi in previous session, but pods show 512Mi (VPA override legacy)
- VPA target: 2.77Gi | Upper: 6.90Gi
- **New**: top-level resources: req 250m/2Gi, lim 2/4Gi; podSpec.containers mysql: same

### traefik auth-proxy & bot-block-proxy — VPA says need 100Mi, limit is 32Mi
- File: stacks/platform/modules/traefik/main.tf
- **New**: req 5m/32Mi, lim 50m/128Mi

## Wave 2: STANDALONE STACKS — containers without explicit resources

### affine — over-provisioned (2 CPU / 4Gi, uses 4m/174Mi)
- VPA upper: 63m/307Mi
- **New**: req 25m/128Mi, lim 250m/512Mi

### aiostreams — mem at 215Mi with 768Mi limit, VPA says 641Mi target
- **New**: req 25m/256Mi, lim 500m/1Gi

### audiobookshelf — no resources, 55Mi usage
- VPA upper: 15m/170Mi
- **New**: req 15m/64Mi, lim 250m/512Mi

### changedetection — sockpuppetbrowser (Chromium) + changedetection
- changedetection: VPA 15m/100Mi | **New**: req 15m/64Mi, lim 250m/256Mi
- sockpuppetbrowser: Chromium needs more | **New**: req 25m/128Mi, lim 500m/512Mi

### cyberchef — tiny (8Mi), no resources
- **New**: req 10m/32Mi, lim 100m/128Mi

### dawarich — Rails app at 438Mi
- VPA upper: 15m/838Mi
- **New**: req 15m/256Mi, lim 250m/1Gi

### diun — tiny (24Mi)
- **New**: req 10m/32Mi, lim 100m/128Mi

### echo — 5 replicas, tiny (19-30Mi each)
- **New**: req 10m/32Mi, lim 100m/128Mi

### excalidraw — tiny (2Mi)
- **New**: req 10m/16Mi, lim 100m/64Mi

### flaresolverr — Chromium at 148Mi/256Mi (58%)
- VPA upper: 15m/348Mi
- **New**: req 25m/128Mi, lim 500m/512Mi

### freshrss — 56Mi
- VPA upper: 15m/167Mi
- **New**: req 15m/64Mi, lim 250m/256Mi

### hackmd — Node.js at 82Mi
- VPA upper: 15m/256Mi
- **New**: req 15m/64Mi, lim 250m/512Mi

### isponsorblocktv — 42Mi
- **New**: req 10m/32Mi, lim 150m/256Mi

### linkwarden — Next.js at 682Mi
- VPA upper: 15m/1.04Gi
- **New**: req 25m/256Mi, lim 500m/1.5Gi

### n8n — workflow automation at 425Mi
- VPA upper: 15m/766Mi
- **New**: req 25m/256Mi, lim 500m/1Gi

### navidrome — music at 62Mi
- VPA upper: 15m/179Mi
- **New**: req 15m/64Mi, lim 250m/384Mi

### ntfy — 20Mi
- **New**: req 10m/32Mi, lim 100m/128Mi

### owntracks — tiny (1Mi)
- **New**: req 10m/16Mi, lim 100m/64Mi

### privatebin — 46Mi
- **New**: req 10m/32Mi, lim 150m/256Mi

### send — 53Mi
- **New**: req 10m/32Mi, lim 150m/256Mi

### shadowsocks — tiny (0Mi)
- **New**: req 10m/16Mi, lim 100m/64Mi

### tandoor — Django at 754Mi
- VPA upper: 15m/1.14Gi
- **New**: req 25m/256Mi, lim 250m/1.5Gi

### tor-proxy — 61Mi
- VPA upper: 15m/167Mi
- **New**: req 10m/64Mi, lim 150m/256Mi

### wealthfolio — tiny (8Mi)
- **New**: req 10m/32Mi, lim 100m/128Mi

### networking-toolbox — tiny, 3 replicas
- **New**: req 10m/32Mi, lim 100m/128Mi

### tuya-bridge — IoT bridge, 3 replicas
- VPA upper: 15m/100Mi
- **New**: req 10m/32Mi, lim 150m/256Mi

### rybbit — Node.js backend at 185Mi
- **New**: req 25m/128Mi, lim 250m/512Mi
### rybbit-client — 89Mi
- **New**: req 10m/64Mi, lim 150m/256Mi

## Wave 3: PLATFORM MODULES — containers without explicit resources

### mailserver — docker-mailserver at 183Mi (needs more for ClamAV)
- VPA upper: 15m/317Mi
- **New**: req 25m/128Mi, lim 500m/512Mi
### dovecot-exporter
- **New**: req 10m/16Mi, lim 100m/64Mi

### cloudflared — 31-59Mi each, 3 replicas
- VPA upper: 15m/110Mi
- **New**: req 15m/32Mi, lim 200m/256Mi

### pgadmin — 265Mi
- VPA upper: 15m/413Mi
- **New**: req 25m/128Mi, lim 500m/512Mi

### phpmyadmin — 46Mi
- VPA upper: 15m/100Mi
- **New**: req 15m/32Mi, lim 250m/256Mi

### crowdsec-web — 46Mi
- **New**: req 15m/32Mi, lim 250m/256Mi

### xray — 11Mi
- **New**: req 10m/32Mi, lim 100m/128Mi

### wireguard — tiny (2Mi)
- **New**: req 10m/16Mi, lim 100m/128Mi
### wireguard prometheus-exporter
- **New**: req 10m/16Mi, lim 50m/64Mi

### k8s-portal — 14Mi
- **New**: req 10m/32Mi, lim 100m/128Mi

## Wave 4: GPU CONTAINERS — add CPU/mem to GPU-only containers

### ollama — SPECIAL: remove limits, keep minimal requests + GPU
- **New**: req 100m/256Mi, lim nvidia.com/gpu=1 ONLY (no CPU/mem limits)

### frigate — highest mem (3835Mi), CPU (860m)
- VPA upper: 1.8 CPU, 6.65Gi mem
- **New**: req 500m/2Gi, lim 4/8Gi + GPU:1

### immich-machine-learning — 1215Mi
- VPA upper: 15m/2.90Gi
- **New**: req 100m/1Gi, lim 2/4Gi + GPU:1

### immich-server — no resources, 404Mi, VPA 920m CPU
- **New**: req 100m/256Mi, lim 2/2Gi

### immich-postgresql — no resources, 268Mi
- **New**: req 50m/256Mi, lim 1/1Gi

### ollama-ui — 658Mi, no resources
- VPA upper: 15m/969Mi
- **New**: req 25m/256Mi, lim 500m/1.5Gi

### whisper — 628Mi, no resources
- VPA upper: 15m/969Mi
- **New**: req 25m/256Mi, lim 500m/1.5Gi

### piper — 32Mi
- **New**: req 25m/64Mi, lim 250m/512Mi

## Wave 5: RIGHT-SIZE OVER-PROVISIONED

### kms-web-page — uses 0m/10Mi but has 500m/512Mi Guaranteed QoS
- **New**: req 10m/16Mi, lim 50m/64Mi

### kms (windows) — uses 0m/0Mi but has 1/512Mi
- **New**: req 10m/32Mi, lim 100m/128Mi

### city-guesser — uses 1m/23Mi but has 250m/500m CPU req
- **New**: req 10m/32Mi, lim 100m/256Mi

### blog — uses 0m/17Mi but has 250m/500m
- **New**: req 10m/32Mi, lim 100m/256Mi

### travel-blog — uses 0m/9Mi, has 250m/500m
- **New**: req 10m/32Mi, lim 100m/256Mi

### webhook-handler — uses 1m/8Mi, has 250m/500m
- **New**: req 10m/32Mi, lim 100m/256Mi

### coturn — uses 1m/7Mi, has 100m/1 CPU
- **New**: req 10m/32Mi, lim 100m/128Mi

### health — uses 2m/101Mi, has 100m/1
- **New**: req 15m/64Mi, lim 250m/256Mi

### plotting-book — uses 0m/22Mi, has 50m/500m
- **New**: req 10m/32Mi, lim 100m/256Mi

### resume/printer — uses 3m/109Mi, VPA says 1.29Gi mem (Chromium!)
- **New**: req 25m/128Mi, lim 500m/1.5Gi (Chromium headless)

### resume — uses 1m/116Mi, has 25m/500m
- **New**: req 15m/64Mi, lim 250m/384Mi

### openclaw/modelrelay — uses low, VPA upper 1.22Gi mem
- **New**: req 25m/64Mi, lim 500m/512Mi

### atuin — uses 1m/2Mi
- **New**: req 10m/16Mi, lim 100m/128Mi

### vaultwarden — uses 1m/49Mi
- **New**: req 10m/32Mi, lim 100m/256Mi

### f1-stream — uses 7m/53Mi
- **New**: req 25m/64Mi, lim 250m/256Mi

### speedtest — uses 1m/147Mi, has 25m/500m
- VPA upper: 418m CPU (spikes during tests!)
- **New**: req 25m/128Mi, lim 1/512Mi

### netbox — uses 1m/480Mi
- VPA upper: 383m CPU, 605Mi mem
- **New**: req 25m/256Mi, lim 500m/1Gi

### meshcentral — uses 1m/127Mi
- VPA upper: 15m/367Mi
- **New**: req 15m/64Mi, lim 250m/512Mi

### forgejo — uses 1m/170Mi
- VPA upper: 15m/284Mi
- **New**: req 15m/64Mi, lim 250m/512Mi

### calibre-web-automated — uses 1m/196Mi
- VPA upper: 63m/829Mi
- **New**: req 25m/256Mi, lim 500m/1Gi

### paperless-ngx — uses 4m/691Mi, VPA upper 1.70Gi
- **New**: req 50m/512Mi, lim 1/2Gi

### realestate-crawler-api — uses 2m/133Mi, has 50m/2000m CPU lim
- **New**: req 15m/64Mi, lim 250m/512Mi

### realestate-crawler-celery-beat — uses 0m/107Mi
- **New**: req 10m/64Mi, lim 100m/256Mi

### osrm-bicycle — uses 0m/366Mi
- VPA upper: 15m/679Mi
- **New**: req 15m/256Mi, lim 100m/1Gi

### osrm-foot — no resources, uses 0m/359Mi
- VPA upper similar to bicycle
- **New**: req 15m/256Mi, lim 100m/1Gi

### freedify — uses 2m/57-68Mi, has 100m/500m
- **New**: req 15m/64Mi, lim 250m/256Mi

### onlyoffice — uses 3m/1007Mi, has 250m/8 CPU (177x waste on CPU)
- Keep memory at 4Gi (needs it), reduce CPU
- **New**: req 100m/512Mi, lim 2/4Gi
