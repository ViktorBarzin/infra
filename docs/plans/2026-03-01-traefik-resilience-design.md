# Traefik Resilience Hardening Design

**Date**: 2026-03-01
**Status**: Approved

## Problem Statement

Traefik is the single ingress point for 70+ services. It has downstream dependencies (ForwardAuth to Poison Fountain, ForwardAuth to Authentik) that are **fail-closed** with **unlimited timeouts**. If these dependencies go down or hang, the entire cluster's public-facing services return 502 or hang indefinitely.

Additionally, no PodDisruptionBudgets exist, all 3 Traefik replicas can land on the same node, and there are no retries for transient backend failures.

## Current State

### Dependency Map (Request Path)

```
Client → Cloudflare → MetalLB (10.0.20.202) → Traefik (1 of 3 replicas)
  → rate-limit .................... IN-PROCESS
  → csp-headers ................... IN-PROCESS
  → crowdsec (plugin) ............. FAIL-OPEN ✓ (already resilient)
  → ai-bot-block (ForwardAuth) .... FAIL-CLOSED ✗ (Poison Fountain)
  → anti-ai-headers ............... IN-PROCESS
  → strip-accept-encoding ......... IN-PROCESS
  → anti-ai-trap-links (plugin) ... IN-PROCESS
  → [if protected=true]:
    → authentik-forward-auth ....... FAIL-CLOSED ✗ (Authentik outpost)
  → Backend Service
```

### Risk Assessment

| Dependency | Fail Mode | Blast Radius | Likelihood | Mitigation |
|---|---|---|---|---|
| Poison Fountain (ai-bot-block) | FAIL-CLOSED | ALL services (default middleware) | Medium (tier 4-aux, 2 replicas) | NONE |
| Authentik (forward auth) | FAIL-CLOSED | Protected services (~4) | Low (3 replicas, tier 1-cluster) | Alert only |
| CrowdSec LAPI | FAIL-OPEN | None | Low | Fully configured |
| Response header timeout | Unlimited (0s) | ALL services (hung backend) | Medium | NONE |
| Pod scheduling | All on same node possible | ALL services | Medium | NONE |
| Node drain | Can evict all replicas | ALL services | During maintenance | NONE |

## Design

### 1. ForwardAuth Resilience (Nginx Resilience Proxies)

#### 1a. AI Bot Block → Fail-Open

Deploy a small nginx reverse proxy in front of Poison Fountain:
- Normal operation: proxies request to `poison-fountain:8080/auth`, returns its response
- Poison Fountain down: nginx catches 502/503/504, returns **200** (allow all traffic)
- The other 4 anti-AI layers (headers, trap links, tarpit, poison content) still work

Update the `ai-bot-block` ForwardAuth middleware to point at the nginx proxy instead of directly at Poison Fountain.

**Nginx config sketch:**
```nginx
upstream poison_fountain {
    server poison-fountain.poison-fountain.svc.cluster.local:8080;
}
server {
    listen 8080;
    location /auth {
        proxy_pass http://poison_fountain;
        proxy_connect_timeout 3s;
        proxy_read_timeout 5s;
        proxy_intercept_errors on;
        error_page 502 503 504 =200 /fallback-allow;
    }
    location = /fallback-allow {
        return 200;
    }
    location /healthz {
        return 200 "ok";
    }
}
```

**Deployment**: 2 replicas, tier `0-core`, topology spread across nodes, minimal resources (10m CPU, 16Mi memory).

#### 1b. Authentik → BasicAuth Fallback

Deploy a similar nginx proxy in front of Authentik's outpost:
- Normal operation: proxies to `ak-outpost-...:9000`, returns Authentik's response (SSO)
- Authentik down: falls back to nginx `auth_basic` with htpasswd credentials from a Kubernetes secret
- Protected services remain accessible to admins via basicAuth during Authentik outages

Update the `authentik-forward-auth` middleware to point at the nginx proxy.

**Nginx config sketch:**
```nginx
upstream authentik {
    server ak-outpost-authentik-embedded-outpost.authentik.svc.cluster.local:9000;
}
server {
    listen 9000;
    location /outpost.goauthentik.io/auth/traefik {
        proxy_pass http://authentik;
        proxy_connect_timeout 3s;
        proxy_read_timeout 5s;
        proxy_intercept_errors on;
        error_page 502 503 504 = @fallback_auth;
    }
    location @fallback_auth {
        auth_basic "Emergency Access";
        auth_basic_user_file /etc/nginx/htpasswd;
        # Return 200 with required headers if basicAuth passes
        add_header X-authentik-username $remote_user;
        return 200;
    }
    location /healthz {
        return 200 "ok";
    }
}
```

**htpasswd secret**: Generated from existing admin credentials, stored in a Kubernetes secret, mounted into the nginx pod.

### 2. Pod Scheduling & Disruption Protection

#### 2a. Traefik Topology Spread + PDB

Add to Traefik Helm values:
```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app.kubernetes.io/name: traefik

podDisruptionBudget:
  enabled: true
  minAvailable: 2
```

#### 2b. Authentik PDB

Add to Authentik Helm values:
```yaml
server:
  pdb:
    enabled: true
    minAvailable: 2
```

#### 2c. Poison Fountain Tier Bump

Change Poison Fountain namespace tier from `4-aux` to `1-cluster`:
- File: `stacks/poison-fountain/main.tf`
- Change: `tier = local.tiers.aux` → `tier = local.tiers.cluster`
- Effect: priority bumped from 200K to 800K, preemption enabled, LimitRange defaults change (512Mi default memory, max 4Gi)

### 3. Timeout & Backend Protection

#### 3a. Response Header Timeout

Change from unlimited to 30s:
```
--serversTransport.forwardingTimeouts.responseHeaderTimeout=30s
```

Prevents hung backends from holding Traefik goroutines indefinitely.

#### 3b. ForwardAuth Proxy Timeouts

The nginx resilience proxies use 3s connect / 5s read timeouts. If the upstream doesn't respond within 5s, the fallback activates. This is much faster than waiting for the backend to eventually time out.

#### 3c. Retry Middleware

Add a `retry` middleware to the default chain in ingress_factory:
```yaml
retry:
  attempts: 2
  initialInterval: 100ms
```

Handles transient 502/503 from backends that are restarting. Only retries on network errors and 5xx.

### 4. Monitoring & Alerting

#### 4a. PoisonFountainDown Alert

```yaml
- alert: PoisonFountainDown
  expr: kube_deployment_status_replicas_available{namespace="poison-fountain", deployment="poison-fountain"} == 0
  for: 2m
  labels:
    severity: critical
  annotations:
    summary: "Poison Fountain is down - AI bot blocking degraded to fail-open"
```

#### 4b. Alert Inhibition

When `TraefikDown` fires, suppress `PoisonFountainDown`.

#### 4c. ForwardAuthFailing Alert

Track when the nginx resilience proxies are serving fallback responses (meaning the real auth services are down):

```yaml
- alert: ForwardAuthFailing
  expr: rate(nginx_upstream_responses_total{status_code="502"}[5m]) > 0
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "ForwardAuth fallback active - check Authentik/Poison Fountain"
```

(Exact metric depends on nginx exporter configuration — may need a custom approach like logging fallback hits and counting with promtail.)

## Files to Modify

| File | Change |
|---|---|
| `stacks/platform/modules/traefik/main.tf` | Add topology spread, PDB, response header timeout |
| `stacks/platform/modules/traefik/middleware.tf` | Update ForwardAuth addresses to point at resilience proxies, add retry middleware |
| `stacks/poison-fountain/main.tf` | Change tier to `1-cluster`, add resilience proxy deployment |
| `stacks/platform/modules/authentik/main.tf` | Add PDB, add auth resilience proxy deployment |
| `modules/kubernetes/ingress_factory/main.tf` | Add retry middleware to default chain |
| `stacks/platform/modules/monitoring/prometheus_chart_values.tpl` | Add PoisonFountainDown alert, ForwardAuthFailing alert, alert inhibition |

## Out of Scope

- Circuit breakers (per-service complexity not worth it for homelab)
- Plugin pre-baking into Docker image (accepted risk)
- Active health checks on backends (K8s readiness probes sufficient)

## Rollback Plan

Each change is independent and can be reverted individually:
- Resilience proxies: revert ForwardAuth addresses back to direct service URLs
- PDBs: remove from Helm values
- Timeouts: revert to `0s`
- Retry middleware: remove from ingress_factory chain
- Alerts: remove from Prometheus config
