# chrome-broker — session broker + FleetView for the worker pool.
#
# Runs on the stock Playwright/python image (same as the snapshot sidecars) with
# broker.py + templates + the static FleetView mounted via ConfigMap — NO custom
# image, NO GHA build (the gate.py pattern). Everything it runs is pure stdlib,
# the FleetView thumbnail SUBPROCESS (screenshot.py) included: since 2026-09-23 it
# speaks raw CDP through cdp_cookies.py's websocket client, so nothing is
# pip-installed at startup.
#
# See docs/plans/2026-07-13-chrome-service-pool-{design,plan}.md and files/broker/.

resource "kubernetes_config_map_v1" "broker_scripts" {
  metadata {
    name      = "chrome-broker-scripts"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
    labels    = local.labels
  }
  data = {
    "broker.py"       = file("${path.module}/files/broker/broker.py")
    "worker_pod.json" = file("${path.module}/files/broker/worker_pod.json")
    "screenshot.py"   = file("${path.module}/files/broker/screenshot.py")
    "index.html"      = file("${path.module}/files/broker/index.html")
    # Shared with the snapshot-harvester (see main.tf's snapshot-scripts
    # ConfigMap) so the seed and the hourly snapshot read the master the
    # same way. Lands beside broker.py in /broker, which is how it imports.
    "cdp_cookies.py" = file("${path.module}/files/broker/cdp_cookies.py")
  }
}

resource "kubernetes_deployment" "broker" {
  metadata {
    name      = "chrome-broker"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
    labels    = merge(local.labels, { app = "chrome-broker" })
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = 1
        max_unavailable = 0
      }
    }
    selector {
      match_labels = { app = "chrome-broker" }
    }
    template {
      metadata {
        labels = { app = "chrome-broker" }
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = "8080"
          "prometheus.io/path"   = "/metrics"
        }
      }
      spec {
        service_account_name = kubernetes_service_account.broker.metadata[0].name
        security_context {
          run_as_user  = 1000
          run_as_group = 1000
          fs_group     = 1000
          seccomp_profile { type = "RuntimeDefault" }
        }
        container {
          name              = "broker"
          image             = local.python_image # mcr.microsoft.com/playwright/python:v1.48.0-noble
          image_pull_policy = "IfNotPresent"
          command           = ["python3", "/broker/broker.py"]
          env {
            name  = "NAMESPACE"
            value = local.namespace
          }
          env {
            name  = "MAX_WORKERS"
            value = "6"
          }
          env {
            name  = "IDLE_TTL_SECONDS"
            value = "1200"
          }
          env {
            name  = "SESSION_DEADLINE_SECONDS"
            value = "3600"
          }
          env {
            name  = "PORT"
            value = "8080"
          }
          env {
            name  = "PYTHONUNBUFFERED"
            value = "1"
          }
          # One hub per person (broker.py Hub / resolve_hub). A request's bearer
          # (that person's hub read token) picks the hub its seed comes from and
          # the namespace its worker runs in. The first entry is Viktor's: FleetView
          # and in-cluster callers without a bearer (tv) act on it. Tokens come
          # from their own variables below, so this JSON holds no secret.
          env {
            name = "HUBS"
            value = jsonencode([
              { user = "wizard", namespace = local.namespace, warm = true,
              cdp = "http://chrome-service.${local.namespace}.svc:9222", token_env = "HUB_TOKEN_WIZARD" },
              { user = "emo", namespace = "chrome-emo",
              cdp = "http://chrome-hub.chrome-emo.svc:9222", token_env = "HUB_TOKEN_EMO" },
            ])
          }
          env {
            name = "HUB_TOKEN_WIZARD"
            value_from {
              secret_key_ref {
                name = "chrome-service-secrets"
                key  = "api_bearer_token"
              }
            }
          }
          env {
            name = "HUB_TOKEN_EMO"
            value_from {
              secret_key_ref {
                name     = "chrome-emo-hub-token"
                key      = "api_bearer_token"
                optional = true
              }
            }
          }
          port {
            name           = "http"
            container_port = 8080
            protocol       = "TCP"
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
          volume_mount {
            name       = "broker"
            mount_path = "/broker"
            read_only  = true
          }
          resources {
            requests = { cpu = "20m", memory = "256Mi" }
            limits   = { memory = "512Mi" }
          }
        }
        volume {
          name = "broker"
          config_map {
            name         = kubernetes_config_map_v1.broker_scripts.metadata[0].name
            default_mode = "0555"
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      # The container image is deliberately NOT ignored, so Terraform
      # re-asserts the pinned local.python_image (same reasoning as main.tf).
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      metadata[0].labels["tier"],
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "broker" {
  metadata {
    name      = "chrome-fleet"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
    labels    = merge(local.labels, { app = "chrome-broker" })
  }
  spec {
    selector = { app = "chrome-broker" }
    port {
      name        = "http"
      port        = 8080
      target_port = 8080
      protocol    = "TCP"
    }
  }
}

module "ingress_fleet" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.chrome_service.metadata[0].name
  name            = "chrome-fleet"
  host            = "chrome-fleet"
  service_name    = kubernetes_service.broker.metadata[0].name
  port            = 8080
  tls_secret_name = var.tls_secret_name
  # FleetView is a control surface for Viktor's pool sessions (lists + kills
  # them) — gate every request with Authentik. A users-only host in
  # stacks/authentik/forward-auth-apps.json (Viktor and svc-agent), so
  # allowed_groups stays at the default. Requests routed through this host need
  # no bearer and act on Viktor's hub (broker.py resolve_hub).
  auth = "required"
  extra_annotations = {
    "gethomepage.dev/enabled"     = "true"
    "gethomepage.dev/name"        = "FleetView"
    "gethomepage.dev/description" = "chrome-service pool — live agent browser sessions"
    "gethomepage.dev/icon"        = "chromium.png"
    "gethomepage.dev/group"       = "Infrastructure"
  }
}

# The broker API for `homelab browser` on the devvm: LAN-only, every request
# carries the caller's hub read token (~/.config/chrome-hub/hub.json), which
# decides whose seed and namespace it gets. Replaces port-forwarding the broker
# Service, which needed pods/portforward across chrome-service.
module "ingress_fleet_api" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": the CLI holds no SSO cookie; the LAN allowlist plus the hub
  # bearer that broker.py resolve_hub requires on this host gate it.
  auth                    = "none"
  dns_type                = "internal"
  allow_local_access_only = true
  external_monitor        = false
  namespace               = kubernetes_namespace.chrome_service.metadata[0].name
  name                    = "chrome-fleet-api"
  host                    = "chrome-fleet-api"
  service_name            = kubernetes_service.broker.metadata[0].name
  port                    = 8080
  tls_secret_name         = var.tls_secret_name
  # An acquire waits for a cold worker pod (up to ~45s).
  skip_default_rate_limit = true
  extra_annotations = {
    "gethomepage.dev/enabled" = "false"
  }
}

# Who may reach the broker at all. Through Traefik (FleetView behind Authentik,
# the LAN-only API behind bearers), and in-cluster from tv, which by Viktor's
# decision keeps using his hub without a bearer, plus Prometheus.
resource "kubernetes_network_policy_v1" "broker_ingress" {
  metadata {
    name      = "chrome-broker-ingress"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = { app = "chrome-broker" }
    }
    policy_types = ["Ingress"]
    ingress {
      ports {
        port     = 8080
        protocol = "TCP"
      }
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "traefik" }
        }
      }
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "tv" }
        }
      }
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "monitoring" }
        }
      }
    }
  }
}

# emo's hub token, synced into this namespace for the broker (HUB_TOKEN_EMO).
# Only that one property: the rest of secret/chrome-emo stays in chrome-emo.
resource "kubernetes_manifest" "emo_hub_token" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "chrome-emo-hub-token"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "chrome-emo-hub-token"
      }
      data = [{
        secretKey = "api_bearer_token"
        remoteRef = {
          key      = "chrome-emo"
          property = "api_bearer_token"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.chrome_service]
}

# Custom namespace quota (replaces the Kyverno tier-4-aux tier-quota — the ns is
# labelled resource-governance/custom-quota=true, so Kyverno stops generating it).
# Sized for the pool: master(2Gi) + broker(0.25Gi) + burst-6 workers(2Gi req / 4Gi
# lim each) + backup/harvester CronJob pods. requests.memory is the ceiling that
# bounds a full burst; count/pods is the runaway-create backstop (broker also
# self-limits to MAX_WORKERS=6). limits.memory headroom covers 6×4Gi worker limits.
resource "kubernetes_resource_quota" "pool" {
  metadata {
    name      = "chrome-pool"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"    = "4"
      "requests.memory" = "16Gi"
      "limits.memory"   = "40Gi"
      "count/pods"      = "14"
    }
  }
}
