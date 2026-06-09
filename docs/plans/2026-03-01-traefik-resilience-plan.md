# Traefik Resilience Hardening Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make Traefik resilient against downstream dependency failures (ForwardAuth services, hung backends) while preventing pod scheduling and disruption issues.

**Architecture:** Deploy nginx resilience proxies in front of fail-closed ForwardAuth services (Poison Fountain, Authentik), add PodDisruptionBudgets, topology spread constraints, response timeouts, retry middleware, and monitoring alerts.

**Tech Stack:** Terraform/Terragrunt, Kubernetes, Nginx, Traefik CRDs, Prometheus

---

### Task 1: Bump Poison Fountain tier from aux to cluster

This is the simplest change and has no dependencies. Bumping the tier ensures Poison Fountain isn't evicted under memory pressure.

**Files:**
- Modify: `stacks/poison-fountain/main.tf:10` (namespace tier label)
- Modify: `stacks/poison-fountain/main.tf:52` (deployment tier label)

**Step 1: Change namespace tier**

In `stacks/poison-fountain/main.tf`, line 10, change:
```hcl
tier = local.tiers.aux
```
to:
```hcl
tier = local.tiers.cluster
```

**Step 2: Change deployment tier label**

In `stacks/poison-fountain/main.tf`, line 52, change:
```hcl
tier = local.tiers.aux
```
to:
```hcl
tier = local.tiers.cluster
```

**Step 3: Verify the plan**

Run:
```bash
cd stacks/poison-fountain && terragrunt plan --non-interactive 2>&1 | tail -30
```
Expected: Plan shows namespace and deployment label changes from `4-aux` to `1-cluster`. No resource destruction.

**Step 4: Apply**

Run:
```bash
cd stacks/poison-fountain && terragrunt apply --non-interactive
```

**Step 5: Verify the new LimitRange and PriorityClass**

Run:
```bash
kubectl --kubeconfig $(pwd)/config describe limitrange tier-defaults -n poison-fountain
kubectl --kubeconfig $(pwd)/config get pods -n poison-fountain -o jsonpath='{.items[*].spec.priorityClassName}'
```
Expected: LimitRange shows `1-cluster` defaults (512Mi default memory, max 4Gi). Priority class is `tier-1-cluster`.

**Step 6: Commit**

```bash
git add stacks/poison-fountain/main.tf
git commit -m "[ci skip] bump poison-fountain tier from aux to cluster (critical path for all ingress)"
```

---

### Task 2: Deploy bot-block resilience proxy (nginx fail-open in front of Poison Fountain)

Deploy an nginx reverse proxy in the `traefik` namespace that proxies to Poison Fountain's `/auth` endpoint and returns 200 (allow) if Poison Fountain is unreachable.

**Files:**
- Modify: `stacks/platform/modules/traefik/main.tf` (add nginx deployment, service, configmap)
- Modify: `stacks/platform/modules/traefik/middleware.tf:287` (update ai-bot-block ForwardAuth address)

**Step 1: Add nginx configmap for bot-block proxy**

Add to end of `stacks/platform/modules/traefik/main.tf` (before the closing of the file):

```hcl
# Resilience proxy for ai-bot-block ForwardAuth
# Returns 200 (allow all) when Poison Fountain is unreachable
resource "kubernetes_config_map" "bot_block_proxy_config" {
  metadata {
    name      = "bot-block-proxy-config"
    namespace = kubernetes_namespace.traefik.metadata[0].name
  }

  data = {
    "default.conf" = <<-EOT
      upstream poison_fountain {
          server poison-fountain.poison-fountain.svc.cluster.local:8080;
      }
      server {
          listen 8080;
          location /auth {
              proxy_pass http://poison_fountain;
              proxy_connect_timeout 3s;
              proxy_read_timeout 5s;
              proxy_send_timeout 5s;
              proxy_intercept_errors on;
              error_page 502 503 504 =200 /fallback-allow;
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;
          }
          location = /fallback-allow {
              internal;
              return 200 "allowed";
          }
          location /healthz {
              access_log off;
              return 200 "ok";
          }
      }
    EOT
  }
}
```

**Step 2: Add nginx deployment for bot-block proxy**

Add after the configmap:

```hcl
resource "kubernetes_deployment" "bot_block_proxy" {
  metadata {
    name      = "bot-block-proxy"
    namespace = kubernetes_namespace.traefik.metadata[0].name
    labels = {
      app = "bot-block-proxy"
    }
  }

  spec {
    replicas = 2
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = 0
        max_surge       = 1
      }
    }
    selector {
      match_labels = {
        app = "bot-block-proxy"
      }
    }
    template {
      metadata {
        labels = {
          app = "bot-block-proxy"
        }
      }
      spec {
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "DoNotSchedule"
          label_selector {
            match_labels = {
              app = "bot-block-proxy"
            }
          }
        }
        container {
          name  = "nginx"
          image = "nginx:1-alpine"

          port {
            container_port = 8080
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/nginx/conf.d"
            read_only  = true
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 3
            period_seconds        = 10
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 2
            period_seconds        = 5
          }

          resources {
            requests = {
              cpu    = "5m"
              memory = "16Mi"
            }
            limits = {
              cpu    = "50m"
              memory = "32Mi"
            }
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.bot_block_proxy_config.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "bot_block_proxy" {
  metadata {
    name      = "bot-block-proxy"
    namespace = kubernetes_namespace.traefik.metadata[0].name
    labels = {
      app = "bot-block-proxy"
    }
  }

  spec {
    selector = {
      app = "bot-block-proxy"
    }
    port {
      name        = "http"
      port        = 8080
      target_port = 8080
    }
  }
}
```

**Step 3: Update ai-bot-block ForwardAuth address**

In `stacks/platform/modules/traefik/middleware.tf`, line 287, change:
```hcl
address            = "http://poison-fountain.poison-fountain.svc.cluster.local:8080/auth"
```
to:
```hcl
address            = "http://bot-block-proxy.traefik.svc.cluster.local:8080/auth"
```

**Step 4: Plan and verify**

Run:
```bash
cd stacks/platform && terragrunt plan --non-interactive 2>&1 | grep -E "will be created|will be updated|Plan:"
```
Expected: 3 resources created (configmap, deployment, service), 1 resource updated (ai-bot-block middleware).

**Step 5: Apply**

Run:
```bash
cd stacks/platform && terragrunt apply --non-interactive
```

**Step 6: Verify the proxy is running and forwarding correctly**

Run:
```bash
kubectl --kubeconfig $(pwd)/config get pods -n traefik -l app=bot-block-proxy
kubectl --kubeconfig $(pwd)/config exec -n traefik deploy/bot-block-proxy -- wget -qO- http://localhost:8080/healthz
```
Expected: 2 pods Running. Health check returns "ok".

**Step 7: Test fail-open behavior**

Temporarily scale Poison Fountain to 0, verify the proxy returns 200:
```bash
kubectl --kubeconfig $(pwd)/config scale deployment poison-fountain -n poison-fountain --replicas=0
kubectl --kubeconfig $(pwd)/config exec -n traefik deploy/bot-block-proxy -- wget -qO- --timeout=10 http://localhost:8080/auth 2>&1
kubectl --kubeconfig $(pwd)/config scale deployment poison-fountain -n poison-fountain --replicas=2
```
Expected: With Poison Fountain at 0 replicas, the proxy returns 200 (fallback). After scaling back, normal forwarding resumes.

**Step 8: Commit**

```bash
git add stacks/platform/modules/traefik/main.tf stacks/platform/modules/traefik/middleware.tf
git commit -m "[ci skip] add bot-block resilience proxy: fail-open when Poison Fountain is down"
```

---

### Task 3: Deploy auth resilience proxy (nginx basicAuth fallback in front of Authentik)

Deploy an nginx proxy that forwards to Authentik's outpost and falls back to basicAuth when Authentik is unreachable.

**Files:**
- Modify: `stacks/platform/modules/traefik/main.tf` (add nginx deployment, service, configmap, htpasswd secret)
- Modify: `stacks/platform/modules/traefik/middleware.tf:36` (update authentik ForwardAuth address)
- Modify: `stacks/platform/modules/traefik/main.tf:1` (add variable for htpasswd)

**Step 1: Add htpasswd variable**

Add to top of `stacks/platform/modules/traefik/main.tf` (after existing variables):
```hcl
variable "auth_fallback_htpasswd" {
  type        = string
  description = "htpasswd-format string for emergency basicAuth fallback when Authentik is down"
  sensitive   = true
}
```

**Step 2: Generate htpasswd and add to terraform.tfvars**

Run (to generate a bcrypt htpasswd entry):
```bash
htpasswd -nbB admin "$(openssl rand -base64 16)"
```
Add the output to `terraform.tfvars`:
```hcl
auth_fallback_htpasswd = "admin:$2y$05$..."  # Generated value
```

**Step 3: Pass variable through platform module**

In `stacks/platform/main.tf`, find the traefik module block and add:
```hcl
auth_fallback_htpasswd = var.auth_fallback_htpasswd
```

Add to `stacks/platform/main.tf` variables (if not already present):
```hcl
variable "auth_fallback_htpasswd" {
  type      = string
  sensitive = true
  default   = ""
}
```

**Step 4: Add nginx configmap, secret, deployment, and service for auth proxy**

Add to end of `stacks/platform/modules/traefik/main.tf`:

```hcl
# Resilience proxy for Authentik ForwardAuth
# Falls back to basicAuth when Authentik is unreachable
resource "kubernetes_secret" "auth_proxy_htpasswd" {
  metadata {
    name      = "auth-proxy-htpasswd"
    namespace = kubernetes_namespace.traefik.metadata[0].name
  }

  data = {
    "htpasswd" = var.auth_fallback_htpasswd
  }
}

resource "kubernetes_config_map" "auth_proxy_config" {
  metadata {
    name      = "auth-proxy-config"
    namespace = kubernetes_namespace.traefik.metadata[0].name
  }

  data = {
    "default.conf" = <<-EOT
      upstream authentik {
          server ak-outpost-authentik-embedded-outpost.authentik.svc.cluster.local:9000;
      }
      server {
          listen 9000;

          # Main auth endpoint - proxy to Authentik, fallback to basicAuth
          location /outpost.goauthentik.io/auth/traefik {
              proxy_pass http://authentik;
              proxy_connect_timeout 3s;
              proxy_read_timeout 5s;
              proxy_send_timeout 5s;
              proxy_intercept_errors on;
              error_page 502 503 504 = @fallback_auth;
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;
              proxy_set_header X-Original-URL $scheme://$http_host$request_uri;
          }

          location @fallback_auth {
              auth_basic "Emergency Access";
              auth_basic_user_file /etc/nginx/htpasswd;
              add_header X-authentik-username $remote_user always;
              add_header X-Auth-Fallback "true" always;
              return 200;
          }

          # Pass through other outpost paths (for OAuth flows when Authentik IS up)
          location /outpost.goauthentik.io/ {
              proxy_pass http://authentik;
              proxy_connect_timeout 3s;
              proxy_read_timeout 10s;
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;
          }

          location /healthz {
              access_log off;
              return 200 "ok";
          }
      }
    EOT
  }
}

resource "kubernetes_deployment" "auth_proxy" {
  metadata {
    name      = "auth-proxy"
    namespace = kubernetes_namespace.traefik.metadata[0].name
    labels = {
      app = "auth-proxy"
    }
  }

  spec {
    replicas = 2
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = 0
        max_surge       = 1
      }
    }
    selector {
      match_labels = {
        app = "auth-proxy"
      }
    }
    template {
      metadata {
        labels = {
          app = "auth-proxy"
        }
      }
      spec {
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "DoNotSchedule"
          label_selector {
            match_labels = {
              app = "auth-proxy"
            }
          }
        }
        container {
          name  = "nginx"
          image = "nginx:1-alpine"

          port {
            container_port = 9000
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/nginx/conf.d"
            read_only  = true
          }
          volume_mount {
            name       = "htpasswd"
            mount_path = "/etc/nginx/htpasswd"
            sub_path   = "htpasswd"
            read_only  = true
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = 9000
            }
            initial_delay_seconds = 3
            period_seconds        = 10
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 9000
            }
            initial_delay_seconds = 2
            period_seconds        = 5
          }

          resources {
            requests = {
              cpu    = "5m"
              memory = "16Mi"
            }
            limits = {
              cpu    = "50m"
              memory = "32Mi"
            }
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.auth_proxy_config.metadata[0].name
          }
        }
        volume {
          name = "htpasswd"
          secret {
            secret_name = kubernetes_secret.auth_proxy_htpasswd.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "auth_proxy" {
  metadata {
    name      = "auth-proxy"
    namespace = kubernetes_namespace.traefik.metadata[0].name
    labels = {
      app = "auth-proxy"
    }
  }

  spec {
    selector = {
      app = "auth-proxy"
    }
    port {
      name        = "http"
      port        = 9000
      target_port = 9000
    }
  }
}
```

**Step 5: Update authentik ForwardAuth address**

In `stacks/platform/modules/traefik/middleware.tf`, line 36, change:
```hcl
address            = "http://ak-outpost-authentik-embedded-outpost.authentik.svc.cluster.local:9000/outpost.goauthentik.io/auth/traefik"
```
to:
```hcl
address            = "http://auth-proxy.traefik.svc.cluster.local:9000/outpost.goauthentik.io/auth/traefik"
```

**Step 6: Plan and verify**

Run:
```bash
cd stacks/platform && terragrunt plan --non-interactive 2>&1 | grep -E "will be created|will be updated|Plan:"
```
Expected: 4 resources created (secret, configmap, deployment, service), 1 resource updated (authentik-forward-auth middleware).

**Step 7: Apply**

Run:
```bash
cd stacks/platform && terragrunt apply --non-interactive
```

**Step 8: Verify proxy is running**

Run:
```bash
kubectl --kubeconfig $(pwd)/config get pods -n traefik -l app=auth-proxy
kubectl --kubeconfig $(pwd)/config exec -n traefik deploy/auth-proxy -- wget -qO- http://localhost:9000/healthz
```
Expected: 2 pods Running. Health check returns "ok".

**Step 9: Commit**

```bash
git add stacks/platform/modules/traefik/main.tf stacks/platform/modules/traefik/middleware.tf stacks/platform/main.tf
git commit -m "[ci skip] add auth resilience proxy: basicAuth fallback when Authentik is down"
```

Note: Do NOT commit terraform.tfvars (it contains the htpasswd secret and is git-crypt encrypted — it will be included in the next push automatically).

---

### Task 4: Add Traefik topology spread, PDB, and response timeout

**Files:**
- Modify: `stacks/platform/modules/traefik/main.tf:26-205` (Helm values)

**Step 1: Add topology spread constraints to Traefik Helm values**

In `stacks/platform/modules/traefik/main.tf`, after the `tolerations = []` line (line 204), add:

```hcl
    topologySpreadConstraints = [{
      maxSkew           = 1
      topologyKey       = "kubernetes.io/hostname"
      whenUnsatisfiable = "DoNotSchedule"
      labelSelector = {
        matchLabels = {
          "app.kubernetes.io/name" = "traefik"
        }
      }
    }]

    podDisruptionBudget = {
      enabled      = true
      minAvailable = 2
    }
```

**Step 2: Change response header timeout**

In `stacks/platform/modules/traefik/main.tf`, line 184, change:
```hcl
"--serversTransport.forwardingTimeouts.responseHeaderTimeout=0s",
```
to:
```hcl
"--serversTransport.forwardingTimeouts.responseHeaderTimeout=30s",
```

**Step 3: Plan and verify**

Run:
```bash
cd stacks/platform && terragrunt plan --non-interactive 2>&1 | grep -E "will be|Plan:"
```
Expected: Helm release will be updated in-place.

**Step 4: Apply**

Run:
```bash
cd stacks/platform && terragrunt apply --non-interactive
```

**Step 5: Verify topology spread**

Run:
```bash
kubectl --kubeconfig $(pwd)/config get pods -n traefik -l app.kubernetes.io/name=traefik -o wide
```
Expected: 3 pods on 3 different nodes.

**Step 6: Verify PDB**

Run:
```bash
kubectl --kubeconfig $(pwd)/config get pdb -n traefik
```
Expected: PDB with minAvailable=2, currentHealthy=3, allowedDisruptions=1.

**Step 7: Commit**

```bash
git add stacks/platform/modules/traefik/main.tf
git commit -m "[ci skip] add Traefik topology spread, PDB (minAvailable=2), and 30s response timeout"
```

---

### Task 5: Add Authentik PDB

**Files:**
- Modify: `stacks/platform/modules/authentik/values.yaml`

**Step 1: Add PDB configuration to Authentik Helm values**

In `stacks/platform/modules/authentik/values.yaml`, add after the `server:` section (after line 33, before `global:`):

```yaml
  pdb:
    enabled: true
    minAvailable: 2
```

So the server section becomes:
```yaml
server:
  replicas: 3
  resources:
    requests:
      cpu: 100m
      memory: 512Mi
    limits:
      cpu: "2"
      memory: 1Gi
  ingress:
    enabled: false
  podAnnotations:
    diun.enable: true
    diun.include_tags: "^202[0-9].[0-9]+.*$"
  pdb:
    enabled: true
    minAvailable: 2
```

**Step 2: Plan and verify**

Run:
```bash
cd stacks/platform && terragrunt plan --non-interactive 2>&1 | grep -E "will be|Plan:"
```
Expected: Helm release will be updated.

**Step 3: Apply**

Run:
```bash
cd stacks/platform && terragrunt apply --non-interactive
```

**Step 4: Verify PDB**

Run:
```bash
kubectl --kubeconfig $(pwd)/config get pdb -n authentik
```
Expected: PDB with minAvailable=2, currentHealthy=3, allowedDisruptions=1.

**Step 5: Commit**

```bash
git add stacks/platform/modules/authentik/values.yaml
git commit -m "[ci skip] add Authentik PDB (minAvailable=2)"
```

---

### Task 6: Add retry middleware to ingress factory

**Files:**
- Modify: `stacks/platform/modules/traefik/middleware.tf` (add retry middleware)
- Modify: `modules/kubernetes/ingress_factory/main.tf:112-113` (add to default chain)

**Step 1: Add retry middleware CRD**

Add to end of `stacks/platform/modules/traefik/middleware.tf`:

```hcl
# Retry middleware for transient backend failures (502/503 during restarts)
resource "kubernetes_manifest" "middleware_retry" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "retry"
      namespace = kubernetes_namespace.traefik.metadata[0].name
    }
    spec = {
      retry = {
        attempts        = 2
        initialInterval = "100ms"
      }
    }
  }

  depends_on = [helm_release.traefik]
}
```

**Step 2: Add retry middleware to ingress factory default chain**

In `modules/kubernetes/ingress_factory/main.tf`, line 112, the middleware chain starts with rate-limit. Add retry as the first middleware (retries should wrap the entire chain):

Change line 112-113 from:
```hcl
      "traefik.ingress.kubernetes.io/router.middlewares" = join(",", compact(concat([
        var.skip_default_rate_limit ? null : "traefik-rate-limit@kubernetescrd",
```
to:
```hcl
      "traefik.ingress.kubernetes.io/router.middlewares" = join(",", compact(concat([
        "traefik-retry@kubernetescrd",
        var.skip_default_rate_limit ? null : "traefik-rate-limit@kubernetescrd",
```

**Step 3: Plan both stacks**

Run:
```bash
cd stacks/platform && terragrunt plan --non-interactive 2>&1 | grep -E "will be|Plan:"
```
Expected: 1 resource created (retry middleware).

Note: The ingress_factory change will take effect the next time any service stack is applied (it's a module used by all stacks). The middleware CRD must exist first.

**Step 4: Apply platform stack**

Run:
```bash
cd stacks/platform && terragrunt apply --non-interactive
```

**Step 5: Verify retry middleware exists**

Run:
```bash
kubectl --kubeconfig $(pwd)/config get middleware -n traefik retry
```
Expected: Middleware `retry` exists.

**Step 6: Commit**

```bash
git add stacks/platform/modules/traefik/middleware.tf modules/kubernetes/ingress_factory/main.tf
git commit -m "[ci skip] add retry middleware (2 attempts, 100ms) to default ingress chain"
```

---

### Task 7: Add Prometheus alerts and inhibition rules

**Files:**
- Modify: `stacks/platform/modules/monitoring/prometheus_chart_values.tpl`

**Step 1: Add PoisonFountainDown alert**

In `stacks/platform/modules/monitoring/prometheus_chart_values.tpl`, in the "Critical Services" alert group (after the AuthentikDown alert, around line 435), add:

```yaml
          - alert: PoisonFountainDown
            expr: (kube_deployment_status_replicas_available{namespace="poison-fountain", deployment="poison-fountain"} or on() vector(0)) < 1
            for: 2m
            labels:
              severity: critical
            annotations:
              summary: "Poison Fountain is down - AI bot blocking degraded to fail-open"
```

**Step 2: Add ForwardAuthFallbackActive alert**

In the "Traefik Ingress" alert group (after the TraefikHighOpenConnections alert, around line 587), add:

```yaml
          - alert: ForwardAuthFallbackActive
            expr: |
              (kube_deployment_status_replicas_available{namespace="poison-fountain", deployment="poison-fountain"} or on() vector(0)) < 1
              or (kube_deployment_status_replicas_available{namespace="authentik", deployment="goauthentik-server"} or on() vector(0)) < 1
            for: 5m
            labels:
              severity: warning
            annotations:
              summary: "ForwardAuth resilience proxy is serving fallback responses - check Poison Fountain and Authentik"
```

**Step 3: Add alert inhibition rule**

In the `inhibit_rules` section (around line 63), add after the existing TraefikDown inhibition:

```yaml
      # Traefik down makes Poison Fountain alerts redundant
      - source_matchers:
          - alertname = TraefikDown
        target_matchers:
          - alertname =~ "PoisonFountainDown|ForwardAuthFallbackActive"
```

**Step 4: Plan and verify**

Run:
```bash
cd stacks/platform && terragrunt plan --non-interactive 2>&1 | grep -E "will be|Plan:"
```
Expected: Helm release updated (Prometheus config changes).

**Step 5: Apply**

Run:
```bash
cd stacks/platform && terragrunt apply --non-interactive
```

**Step 6: Verify alerts are loaded**

Run:
```bash
kubectl --kubeconfig $(pwd)/config exec -n monitoring deploy/prometheus-server -- wget -qO- http://localhost:9090/api/v1/rules 2>&1 | python3 -c "import sys,json; rules=[r['name'] for g in json.load(sys.stdin)['data']['groups'] for r in g['rules']]; print('PoisonFountainDown:', 'PoisonFountainDown' in rules); print('ForwardAuthFallbackActive:', 'ForwardAuthFallbackActive' in rules)"
```
Expected: Both alerts show `True`.

**Step 7: Commit**

```bash
git add stacks/platform/modules/monitoring/prometheus_chart_values.tpl
git commit -m "[ci skip] add PoisonFountainDown and ForwardAuthFallbackActive alerts with inhibition"
```

---

### Task 8: Final verification and push

**Step 1: Run cluster health check**

Run:
```bash
bash scripts/cluster_healthcheck.sh --quiet
```
Expected: No new WARN/FAIL related to our changes.

**Step 2: Verify all resilience proxies are running**

Run:
```bash
kubectl --kubeconfig $(pwd)/config get pods -n traefik -l "app in (bot-block-proxy,auth-proxy)" -o wide
kubectl --kubeconfig $(pwd)/config get pods -n traefik -l app.kubernetes.io/name=traefik -o wide
kubectl --kubeconfig $(pwd)/config get pdb -A
```
Expected: All proxy pods running on different nodes, Traefik pods spread across nodes, PDBs for Traefik and Authentik.

**Step 3: Test a public service is still accessible**

Run:
```bash
curl -s -o /dev/null -w "%{http_code}" https://viktorbarzin.me
```
Expected: 200 (or 301/302 redirect). Not 502.

**Step 4: Push all commits**

Ask user for confirmation, then:
```bash
git push origin master
```
