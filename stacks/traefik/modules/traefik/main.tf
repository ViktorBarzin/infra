variable "tier" { type = string }
variable "redis_host" { type = string }
variable "tls_secret_name" {}
variable "auth_fallback_htpasswd" {
  type        = string
  description = "htpasswd-format string for emergency basicAuth fallback when Authentik is down"
  sensitive   = true
}
variable "x402_wallet_address" {
  type        = string
  default     = ""
  description = "EVM wallet (Base mainnet, 0x…) that receives USDC from x402 payments. Empty = DRY_RUN, gateway always returns 200 to forwardAuth so traffic is unaffected."
}
variable "x402_notify_webhook_url" {
  type        = string
  default     = ""
  description = "Slack-compatible incoming-webhook URL the gateway POSTs to on every successful payment. Empty = no notifications."
  sensitive   = true
}

resource "kubernetes_namespace" "traefik" {
  metadata {
    name = "traefik"
    labels = {
      "app.kubernetes.io/name"     = "traefik"
      "app.kubernetes.io/instance" = "traefik"
      tier                         = var.tier
      "keel.sh/enrolled"           = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "helm_release" "traefik" {
  namespace        = kubernetes_namespace.traefik.metadata[0].name
  create_namespace = false
  name             = "traefik"
  repository       = "https://traefik.github.io/charts"
  chart            = "traefik"
  # Pin to the deployed chart version. Was unpinned, so a refreshed helm repo
  # index silently tries to upgrade to the latest chart on the next apply —
  # chart 41.0.0 rejects this values block's `logs` key ("Additional property
  # logs is not allowed"). Bump deliberately (with values migration), never
  # implicitly. Deployed since 2026-05-30 (release rev 57).
  version = "40.2.0"
  atomic  = true
  timeout = 600

  values = [yamlencode({
    deployment = {
      replicas                      = 3
      terminationGracePeriodSeconds = 60
      lifecycle = {
        preStop = {
          exec = {
            command = ["/bin/sh", "-c", "sleep 15"]
          }
        }
      }
      podAnnotations = {
        "diun.enable"       = "true"
        "diun.include_tags" = "^v\\d+(?:\\.\\d+)?(?:\\.\\d+)?.*$"
      }
      initContainers = [{
        name  = "download-plugins"
        image = "alpine:3"
        command = ["sh", "-c", join("", [
          "set -e; ",
          "STORAGE=/plugins-storage; ",
          "mkdir -p \"$STORAGE/archives/github.com/Aetherinox/traefik-api-token-middleware\"; ",
          "wget -q -T 30 -O \"$STORAGE/archives/github.com/Aetherinox/traefik-api-token-middleware/v0.1.4.zip\" ",
          "\"https://github.com/Aetherinox/traefik-api-token-middleware/archive/refs/tags/v0.1.4.zip\"; ",
          "printf '{\"github.com/Aetherinox/traefik-api-token-middleware\":\"v0.1.4\"}' ",
          "> \"$STORAGE/archives/state.json\"; ",
          "echo \"Plugins pre-downloaded successfully\"",
        ])]
        volumeMounts = [{
          name      = "plugins"
          mountPath = "/plugins-storage"
        }]
      }]
    }

    updateStrategy = {
      type = "RollingUpdate"
      rollingUpdate = {
        maxUnavailable = 0
        maxSurge       = 1
      }
    }

    ingressClass = {
      enabled        = true
      isDefaultClass = true
    }

    providers = {
      kubernetesIngress = {
        enabled                   = true
        allowExternalNameServices = true
        publishedService          = { enabled = true }
      }
      kubernetesCRD = {
        enabled                   = true
        allowExternalNameServices = true
        allowCrossNamespace       = true
      }
    }

    # Enable dashboard API (accessible on port 8080 internally)
    api = {
      insecure = false
    }

    # Entrypoints
    ports = {
      web = {
        port        = 8000
        exposedPort = 80
        protocol    = "TCP"
        http = {
          redirections = {
            entryPoint = {
              to     = "websecure"
              scheme = "https"
            }
          }
        }
        proxyProtocol = {
          trustedIPs = ["10.0.20.1"]
        }
      }
      websecure = {
        port        = 8443
        exposedPort = 443
        protocol    = "TCP"
        http = {
          tls = {
            enabled = true
          }
          middlewares = [
            "traefik-compress@kubernetescrd",
          ]
        }
        http3 = {
          enabled        = true
          advertisedPort = 443
        }
        # Accept PROXY-v2 ONLY from the pfSense HAProxy IPv6 bridge (10.0.20.1)
        # so IPv6 clients (forwarded [2001:470:6e:43d::2] -> here) get their real
        # IP for CrowdSec. Real IPv4 clients arrive with their own source IP
        # (ETP=Local, not 10.0.20.1) and are unaffected.
        proxyProtocol = {
          trustedIPs = ["10.0.20.1"]
        }
      }
      whisper-tcp = {
        port        = 10300
        exposedPort = 10300
        protocol    = "TCP"
        expose      = { default = true }
      }
      piper-tcp = {
        port        = 10200
        exposedPort = 10200
        protocol    = "TCP"
        expose      = { default = true }
      }
    }

    service = {
      type = "LoadBalancer"
      annotations = {
        # Dedicated IP + ETP=Local so direct-app clients keep their real source
        # IP (CrowdSec) and QUIC handshakes pin to one pod. Proxied apps are
        # unaffected — cloudflared targets the in-cluster Traefik Service
        # (traefik.traefik.svc), not this LB IP, so the LB IP can move freely.
        "metallb.io/loadBalancerIPs" = "10.0.20.203"
      }
      spec = {
        externalTrafficPolicy = "Local"
      }
    }

    # Plugins
    experimental = {
      plugins = {
        # Static-token bearer/header auth middleware. Used by services that
        # need gateway-level API-key/bearer enforcement without app-layer auth
        # (e.g. paperless-mcp, which has no native auth). Plugin key
        # `api-token-middleware` is the name to use as the inner key in
        # `Middleware.spec.plugin.<key>` on consuming Middleware CRDs.
        api-token-middleware = {
          moduleName = "github.com/Aetherinox/traefik-api-token-middleware"
          version    = "v0.1.4"
        }
      }
    }

    # Prometheus metrics
    metrics = {
      prometheus = {
        entryPoint           = "metrics"
        addEntryPointsLabels = true
        addServicesLabels    = true
        addRoutersLabels     = true
        buckets              = "0.01,0.05,0.1,0.2,0.5,1.0,2.0,5.0,10.0,30.0"
      }
    }

    # Access logs
    logs = {
      access = {
        enabled = true
      }
    }

    additionalArguments = [
      "--global.checknewversion=false",
      "--global.sendanonymoususage=false",
      # Skip TLS verification for self-signed backend certs (proxmox, idrac, etc.)
      "--serversTransport.insecureSkipVerify=true",
      # Increase timeouts for services like Immich
      "--serversTransport.forwardingTimeouts.dialTimeout=60s",
      "--serversTransport.forwardingTimeouts.responseHeaderTimeout=30s",
      "--serversTransport.forwardingTimeouts.idleConnTimeout=90s",
      # Increase backend connection pool (default maxIdleConnsPerHost=2 is too low)
      "--serversTransport.maxIdleConnsPerHost=100",
      # Entrypoint transport timeouts. NOTE: Traefik respondingTimeouts are HARD caps on
      # total request/response duration (unlike nginx proxy_*_timeout, which reset per read).
      # A finite writeTimeout therefore caps total *download* time regardless of progress —
      # a prior writeTimeout=60s silently truncated large downloads at 60s (HTTP/2 reset).
      #   writeTimeout=0  -> unlimited download size/duration (Traefik's own default; Immich's
      #                      reverse-proxy guidance assumes it — it never sets writeTimeout).
      #   readTimeout=3600s -> one upload may take up to 1h. NOT 0: an unbounded request read
      #                      is the slow-loris vector (hence Traefik's 60s default). Immich has
      #                      no resumable upload, so the window must exceed real upload times.
      "--entryPoints.websecure.transport.respondingTimeouts.readTimeout=3600s",
      "--entryPoints.websecure.transport.respondingTimeouts.writeTimeout=0s",
      "--entryPoints.websecure.transport.respondingTimeouts.idleTimeout=600s",
      # Use forwarded headers from trusted proxies
      "--entryPoints.websecure.forwardedHeaders.insecure=false",
      "--entryPoints.web.forwardedHeaders.insecure=false",
      "--entryPoints.websecure.forwardedHeaders.trustedIPs=173.245.48.0/20,103.21.244.0/22,103.22.200.0/22,103.31.4.0/22,141.101.64.0/18,108.162.192.0/18,190.93.240.0/20,188.114.96.0/20,197.234.240.0/22,198.41.128.0/17,162.158.0.0/15,104.16.0.0/13,104.24.0.0/14,172.64.0.0/13,131.0.72.0/22,10.0.0.0/8,192.168.0.0/16",
      "--entryPoints.web.forwardedHeaders.trustedIPs=173.245.48.0/20,103.21.244.0/22,103.22.200.0/22,103.31.4.0/22,141.101.64.0/18,108.162.192.0/18,190.93.240.0/20,188.114.96.0/20,197.234.240.0/22,198.41.128.0/17,162.158.0.0/15,104.16.0.0/13,104.24.0.0/14,172.64.0.0/13,131.0.72.0/22,10.0.0.0/8,192.168.0.0/16",
    ]

    resources = {
      requests = {
        cpu    = "100m"
        memory = "768Mi"
      }
      limits = {
        memory = "768Mi"
      }
    }

    nodeSelector = {
      "kubernetes.io/os" = "linux"
    }

    tolerations = []

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
  })]
}

# Dashboard resources
module "tls_secret" {
  source          = "../../../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.traefik.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_service" "traefik_dashboard" {
  metadata {
    name      = "traefik-dashboard"
    namespace = kubernetes_namespace.traefik.metadata[0].name
    labels = {
      "app" = "traefik-dashboard"
    }
  }

  spec {
    selector = {
      "app.kubernetes.io/name" = "traefik"
    }
    port {
      name        = "http"
      port        = 8080
      target_port = 8080
      protocol    = "TCP"
    }
  }
}

module "ingress" {
  source          = "../../../../modules/kubernetes/ingress_factory"
  dns_type        = "non-proxied"
  namespace       = kubernetes_namespace.traefik.metadata[0].name
  name            = "traefik"
  service_name    = "traefik-dashboard"
  host            = "traefik"
  port            = 8080
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Traefik"
    "gethomepage.dev/description"  = "Reverse proxy & ingress"
    "gethomepage.dev/icon"         = "traefik.png"
    "gethomepage.dev/group"        = "Core Platform"
    "gethomepage.dev/pod-selector" = ""
  }
}

# Bot-block resilience proxy: nginx reverse proxy in front of Poison Fountain
# Forward-auth target for the ai-bot-block middleware. The poison-fountain bot
# trap is intentionally scaled to 0 (stacks/poison-fountain), so /auth is a
# clean no-op returning 200 (allow-all) rather than proxying to an absent
# upstream. Reloader (annotation on the Deployment below) rolls the pods when
# this ConfigMap changes — openresty does not reload on its own.
resource "kubernetes_config_map" "bot_block_proxy_config" {
  metadata {
    name      = "bot-block-proxy-config"
    namespace = kubernetes_namespace.traefik.metadata[0].name
  }

  data = {
    "default.conf" = <<-EOT
      server {
          listen 8080;

          # Browsers accumulate one authentik_proxy_<random> cookie per Authentik
          # Proxy Provider on the parent domain. With 30+ services under
          # viktorbarzin.me the combined Cookie header exceeds nginx's default
          # 4 x 8k large_client_header_buffers and the ai-bot-block forward-auth
          # rejects it with 400 (and error-pages then shows "Too big request
          # header" 431). NOTE the *binding* limit for browsers is Traefik's
          # HTTP/2 header cap (~64KB, Go maxHeaderListSize, not configurable) —
          # bigger piles are rejected upstream of here regardless. This 256k
          # only keeps bot-block from being a *tighter* bottleneck (and covers
          # HTTP/1.1 clients). poison-fountain (the bot check) ignores cookies.
          # Real fix for >64KB piles = reduce authentik_proxy_* accumulation.
          client_header_buffer_size 8k;
          large_client_header_buffers 8 256k;

          location /auth {
              access_by_lua_block {
                  ngx.req.clear_header("If-Match")
                  ngx.req.clear_header("If-None-Match")
                  ngx.req.clear_header("If-Modified-Since")
                  ngx.req.clear_header("If-Unmodified-Since")
              }
              # poison-fountain (the bot trap) is intentionally scaled to 0
              # (stacks/poison-fountain, replicas=0). With no upstream to
              # consult we short-circuit to allow-all here -- the SAME effective
              # behaviour as the prior proxy_pass + error_page-5xx-to-200
              # fail-open (poison-fountain down => 200 allowed), minus the
              # per-request connect attempt that logged ~51k errors/hr once pod
              # logs shipped to Loki (2026-06-05) and cost up to 100ms/req. To
              # re-enable the trap: restore the upstream + proxy_pass (git
              # history) and scale poison-fountain up.
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

resource "kubernetes_deployment" "bot_block_proxy" {
  metadata {
    name      = "bot-block-proxy"
    namespace = kubernetes_namespace.traefik.metadata[0].name
    labels = {
      app = "bot-block-proxy"
    }
    annotations = {
      # openresty does not hot-reload its ConfigMap-mounted default.conf, so a
      # config change needs a pod roll. Reloader watches the named ConfigMap and
      # rolls this Deployment on change (the missing piece that let stale config
      # run for days before 2026-06-05).
      "configmap.reloader.stakater.com/reload" = "bot-block-proxy-config"
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
          image = "openresty/openresty:alpine"

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
              memory = "64Mi"
            }
            limits = {
              memory = "64Mi"
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
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,
      # KEEL_LIFECYCLE_V1: keel.sh annotations + tier label are stamped on the
      # live object (keel enrollment / resource-governance) — don't strip them.
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"],
      metadata[0].annotations["keel.sh/match-tag"],
      metadata[0].labels["tier"],
    ]
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

# x402 payment gateway — shared forwardAuth target for every ingress that
# wants to issue HTTP 402 to declared AI-bot UAs / accept X-PAYMENT for paid
# access. One deployment serves all hosts; each consumer ingress just adds
# `traefik-x402@kubernetescrd` to its middleware chain.
#
# DRY_RUN until `var.x402_wallet_address` is set. While dry-run, every
# auth call returns 200 (allow) so traffic is unaffected.
resource "kubernetes_deployment" "x402_gateway" {
  metadata {
    name      = "x402-gateway"
    namespace = kubernetes_namespace.traefik.metadata[0].name
    labels    = { app = "x402-gateway" }
  }

  spec {
    replicas = 2 # Stateless; HA across two pods is cheap.
    selector {
      match_labels = { app = "x402-gateway" }
    }
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = 1
        max_unavailable = 0
      }
    }
    template {
      metadata {
        labels = { app = "x402-gateway" }
      }
      spec {
        image_pull_secrets {
          name = "registry-credentials"
        }
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector {
            match_labels = { app = "x402-gateway" }
          }
        }
        container {
          name  = "x402-gateway"
          image = "ghcr.io/viktorbarzin/x402-gateway:latest"
          port {
            name           = "http"
            container_port = 8923
          }
          port {
            name           = "metrics"
            container_port = 9090
          }
          env {
            name  = "MODE"
            value = "forwardauth"
          }
          env {
            name  = "BIND"
            value = ":8923"
          }
          env {
            name  = "METRICS_BIND"
            value = ":9090"
          }
          env {
            name  = "WALLET_ADDRESS"
            value = var.x402_wallet_address
          }
          env {
            name  = "PRICE_LABEL"
            value = "$0.01"
          }
          env {
            name  = "PRICE_USDC_MICROS"
            value = "10000"
          }
          env {
            name  = "NETWORK"
            value = "base"
          }
          env {
            name  = "FACILITATOR_URL"
            value = "https://x402.org/facilitator"
          }
          # Slack incoming-webhook for real-time payment notifications.
          # Reuses the existing Alertmanager channel — payment events appear
          # alongside infra alerts. Reads from secret/viktor.alertmanager_slack_api_url.
          env {
            name  = "NOTIFY_WEBHOOK_URL"
            value = var.x402_notify_webhook_url
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = "metrics"
            }
            initial_delay_seconds = 5
            period_seconds        = 30
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = "metrics"
            }
            initial_delay_seconds = 1
            period_seconds        = 5
          }
          security_context {
            run_as_non_root            = true
            run_as_user                = 65532
            run_as_group               = 65532
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }
        }
      }
    }
  }

  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,
      # KEEL_IGNORE_IMAGE: the GHA->ghcr build (ADR-0002 infra#28) set-images
      # the running :sha8 tag; don't let terragrunt revert it to :latest.
      spec[0].template[0].spec[0].container[0].image,
      # KEEL_LIFECYCLE_V1: keel.sh annotations + tier label are stamped on the
      # live object (keel enrollment / resource-governance) — don't strip them.
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"],
      metadata[0].annotations["keel.sh/match-tag"],
      metadata[0].labels["tier"],
    ]
  }
}

resource "kubernetes_service" "x402_gateway" {
  metadata {
    name      = "x402-gateway"
    namespace = kubernetes_namespace.traefik.metadata[0].name
    labels    = { app = "x402-gateway" }
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/path"   = "/metrics"
      "prometheus.io/port"   = "9090"
    }
  }

  spec {
    selector = { app = "x402-gateway" }
    port {
      name        = "http"
      port        = 8080
      target_port = 8923
    }
    port {
      name        = "metrics"
      port        = 9090
      target_port = 9090
    }
  }
}

resource "kubernetes_pod_disruption_budget_v1" "x402_gateway" {
  metadata {
    name      = "x402-gateway"
    namespace = kubernetes_namespace.traefik.metadata[0].name
  }
  spec {
    min_available = "1"
    selector {
      match_labels = { app = "x402-gateway" }
    }
  }
}

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
          # Reuse connections to the outpost. Without this every forward-auth
          # subrequest (= every request to every auth="required" ingress) opens
          # a fresh TCP connection. Requires HTTP/1.1 + cleared Connection
          # header on the proxy_pass locations below.
          keepalive 32;
      }
      server {
          listen 9000;

          # Browsers accumulate one authentik_proxy_<random> cookie per Authentik
          # Proxy Provider on the parent domain. With 30+ services under
          # viktorbarzin.me the combined Cookie header exceeds nginx's default
          # 4 x 8k large_client_header_buffers and trips "Too big request header"
          # (431). Bump to 8 x 64k so the auth check accepts the pile.
          client_header_buffer_size 8k;
          large_client_header_buffers 8 64k;

          location /outpost.goauthentik.io/auth/traefik {
              proxy_pass http://authentik;
              proxy_http_version 1.1;
              proxy_set_header Connection "";
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
              # Set ALL X-authentik-* headers to prevent client-supplied header spoofing.
              # Without this, a client could inject fake X-authentik-groups and backends
              # that trust these headers would grant elevated access.
              add_header X-authentik-username $remote_user always;
              add_header X-authentik-uid "" always;
              add_header X-authentik-email "" always;
              add_header X-authentik-name "" always;
              add_header X-authentik-groups "" always;
              add_header X-Auth-Fallback "true" always;
              root /usr/share/nginx/fallback;
              try_files /ok =403;
          }

          location /outpost.goauthentik.io/ {
              proxy_pass http://authentik;
              proxy_http_version 1.1;
              proxy_set_header Connection "";
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

resource "kubernetes_config_map" "auth_proxy_fallback" {
  metadata {
    name      = "auth-proxy-fallback"
    namespace = kubernetes_namespace.traefik.metadata[0].name
  }

  data = {
    "ok" = "authenticated"
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
        annotations = {
          # nginx only reads its config at startup — roll the pods whenever
          # the ConfigMap content changes.
          "checksum/auth-proxy-config" = sha1(kubernetes_config_map.auth_proxy_config.data["default.conf"])
          # The emergency-fallback htpasswd is a subPath secret mount, which
          # does NOT auto-update on change — roll the pods when it rotates so a
          # regenerated emergency password actually takes effect.
          "checksum/auth-proxy-htpasswd" = sha1(var.auth_fallback_htpasswd)
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
          volume_mount {
            name       = "fallback"
            mount_path = "/usr/share/nginx/fallback"
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
              memory = "64Mi"
            }
            limits = {
              memory = "64Mi"
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
        volume {
          name = "fallback"
          config_map {
            name = kubernetes_config_map.auth_proxy_fallback.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,
      # KEEL_LIFECYCLE_V1: keel.sh annotations + tier label are stamped on the
      # live object (keel enrollment / resource-governance) — don't strip them.
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"],
      metadata[0].annotations["keel.sh/match-tag"],
      metadata[0].labels["tier"],
    ]
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
