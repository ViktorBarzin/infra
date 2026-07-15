# chrome-broker — session broker + FleetView for the worker pool.
#
# Runs on the stock Playwright/python image (same as the snapshot sidecars) with
# broker.py + templates + the static FleetView mounted via ConfigMap — NO custom
# image, NO GHA build (the gate.py pattern). broker.py itself is pure stdlib; it
# only needs `playwright` for the seed/screenshot SUBPROCESSES, so the entrypoint
# pip-installs it at startup (same as the snapshot-harvester CronJob — the MS
# image ships browsers but not the pip package). connect_over_cdp needs no local
# browser, so PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1.
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
    "seed_export.py"  = file("${path.module}/files/broker/seed_export.py")
    "screenshot.py"   = file("${path.module}/files/broker/screenshot.py")
    "index.html"      = file("${path.module}/files/broker/index.html")
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
          # pip-install playwright for the seed/screenshot subprocesses (browsers
          # already in the image; skip the download), then run the stdlib broker.
          # Non-root (uid 1000): pip --user into a writable base ($PYTHONUSERBASE),
          # which python3 auto-adds to sys.path for the seed/screenshot subprocesses.
          command = ["bash", "-c"]
          args = [
            <<-EOT
            set -e
            export HOME=/tmp PYTHONUSERBASE=/tmp/py PIP_CACHE_DIR=/tmp/pipcache PIP_DISABLE_PIP_VERSION_CHECK=1
            # patchright (playwright drop-in) for the seed/screenshot subprocesses —
            # avoids the Runtime.enable CDP leak on the master + the caller's page.
            python3 -c 'import patchright' 2>/dev/null \
              || pip install --user --quiet --no-warn-script-location patchright==1.61.1
            exec python3 /broker/broker.py
            EOT
          ]
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
            name  = "PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD"
            value = "1"
          }
          env {
            name  = "PYTHONUNBUFFERED"
            value = "1"
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
  # FleetView is an admin control surface (lists + kills agent sessions) — gate
  # every request with Authentik. The broker has no auth of its own.
  auth = "required"
  extra_annotations = {
    "gethomepage.dev/enabled"     = "true"
    "gethomepage.dev/name"        = "FleetView"
    "gethomepage.dev/description" = "chrome-service pool — live agent browser sessions"
    "gethomepage.dev/icon"        = "chromium.png"
    "gethomepage.dev/group"       = "Infrastructure"
  }
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
