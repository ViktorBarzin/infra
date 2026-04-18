variable "tier" { type = string }
variable "crowdsec_api_key" {
  type      = string
  sensitive = true
}
variable "redis_host" { type = string }
variable "tls_secret_name" {}
variable "auth_fallback_htpasswd" {
  type        = string
  description = "htpasswd-format string for emergency basicAuth fallback when Authentik is down"
  sensitive   = true
}

resource "kubernetes_namespace" "traefik" {
  metadata {
    name = "traefik"
    labels = {
      "app.kubernetes.io/name"     = "traefik"
      "app.kubernetes.io/instance" = "traefik"
      tier                         = var.tier
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
  atomic           = true
  timeout          = 600

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
          "mkdir -p \"$STORAGE/archives/github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin\"; ",
          "wget -q -T 30 -O \"$STORAGE/archives/github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin/v1.4.2.zip\" ",
          "\"https://github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin/archive/refs/tags/v1.4.2.zip\"; ",
          "printf '{\"github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin\":\"v1.4.2\"}' ",
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
        "metallb.io/loadBalancerIPs" = "10.0.20.200"
        "metallb.io/allow-shared-ip" = "shared"
      }
      spec = {
        externalTrafficPolicy = "Cluster"
      }
    }

    # Plugins
    experimental = {
      plugins = {
        crowdsec-bouncer = {
          moduleName = "github.com/maxlerebourg/crowdsec-bouncer-traefik-plugin"
          version    = "v1.4.2"
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
      # Explicit entrypoint timeouts to bound tail latency from slow clients
      "--entryPoints.websecure.transport.respondingTimeouts.readTimeout=60s",
      "--entryPoints.websecure.transport.respondingTimeouts.writeTimeout=60s",
      "--entryPoints.websecure.transport.respondingTimeouts.idleTimeout=180s",
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
  protected       = true
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
# Returns 200 (allow all traffic) if Poison Fountain is unreachable (fail-open)
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
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
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
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
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
