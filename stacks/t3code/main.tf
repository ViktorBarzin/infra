variable "tls_secret_name" {
  type      = string
  sensitive = true
}

resource "kubernetes_namespace" "t3code" {
  metadata {
    name = "t3code"
    labels = {
      "istio-injection" : "disabled"
      tier               = local.tiers.aux
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# TLS secret `tls-secret` (wildcard *.viktorbarzin.me) is auto-cloned into this
# namespace by Kyverno's `sync-tls-secret` ClusterPolicy — no local module or
# cert material needed; the renewal pipeline updates the source and Kyverno
# propagates within seconds.

# === Per-user dispatch + auto-provisioning ===================================
# t3 is single-owner (no in-app multi-user), so each person runs their OWN
# `t3 serve` instance on the DevVM as their own OS user (file perms enforced by
# the uid). A DevVM service `t3-dispatch` (10.0.10.10:3780) routes the single
# hostname t3.viktorbarzin.me by Authentik identity and auto-mints+injects the
# user's t3 session on first visit. Source of truth: /etc/ttyd-user-map. All the
# DevVM-side pieces (t3-serve@ template, reconcile, dispatch, t3-mint, sudoers)
# live in infra/scripts/ and are deployed there (outside TF, like t3-serve and
# terminal-lobby). This stack only owns the K8s edge:
#   Traefik (Authentik forward-auth, auth="required") -> Service/Endpoints
#   -> 10.0.10.10:3780 (t3-dispatch).
# See docs/plans/2026-06-01-t3-auto-provision-{design,plan}.md.
resource "kubernetes_service" "t3code" {
  metadata {
    name      = "t3"
    namespace = kubernetes_namespace.t3code.metadata[0].name
    labels = {
      app = "t3"
    }
  }

  spec {
    port {
      name        = "http"
      port        = 80
      target_port = 3780
    }
  }
}

resource "kubernetes_endpoints" "t3code" {
  metadata {
    name      = "t3"
    namespace = kubernetes_namespace.t3code.metadata[0].name
  }

  subset {
    address {
      ip = "10.0.10.10"
    }
    port {
      name = "http"
      port = 3780
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.t3code.metadata[0].name
  name            = "t3"
  service_name    = kubernetes_service.t3code.metadata[0].name
  tls_secret_name = var.tls_secret_name
  # Authentik forward-auth gates t3.viktorbarzin.me and injects
  # X-authentik-username, which the DevVM t3-dispatch service maps to each user's
  # own `t3 serve` instance (per-user isolation mirroring the terminal stack).
  # The same-origin self-served UI works behind forward-auth (WS carries the
  # Authentik cookie); t3's own pairing/bearer is the inner gate, auto-injected
  # on first visit. Cross-origin clients (native app / app.t3.codes) are
  # intentionally NOT supported here — deferred until the native app is published.
  auth = "required"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "T3 Code"
    "gethomepage.dev/description"  = "Coding-agent GUI (per-user, t3 serve on DevVM)"
    "gethomepage.dev/icon"         = "mdi-robot"
    "gethomepage.dev/group"        = "Infrastructure"
    "gethomepage.dev/pod-selector" = ""
  }
}

# === Drop-attribution probe surface ==========================================
# /probe/* on the t3 host is dispatch's unauthenticated echo surface (see
# scripts/t3-dispatch/probe.go) for the t3-probe below. Guarded against
# Authentik re-walling by `authentik_walloff_targets` in stacks/monitoring.
module "ingress_probe" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": WS echo + healthz for the in-cluster path-health probe; no
  # user data, no t3 instance reachable — auth would break the synthetic client.
  auth             = "none"
  anti_ai_scraping = false  # the probe IS a bot; PoW/UA filtering would block it
  dns_type         = "none" # main `module.ingress` owns the DNS record for this host
  namespace        = kubernetes_namespace.t3code.metadata[0].name
  name             = "t3-probe"
  # secondary/non-UI ingress: no homepage tile (dedupe sweep 2026-07-14)
  homepage_enabled = false
  service_name     = kubernetes_service.t3code.metadata[0].name
  full_host        = "t3.viktorbarzin.me"
  ingress_path     = ["/probe"]
  tls_secret_name  = var.tls_secret_name
}

# t3-probe: differential WS/HTTP prober (see probe.py docstring for the
# attribution model). Runs in-cluster so it measures the shared path WITHOUT
# any user's last mile; Prometheus scrapes it via the static `t3-probe` job
# in stacks/monitoring.
resource "kubernetes_config_map_v1" "t3_probe" {
  metadata {
    name      = "t3-probe"
    namespace = kubernetes_namespace.t3code.metadata[0].name
  }
  data = {
    "probe.py" = file("${path.module}/probe.py")
  }
}

resource "kubernetes_deployment_v1" "t3_probe" {
  metadata {
    name      = "t3-probe"
    namespace = kubernetes_namespace.t3code.metadata[0].name
    labels    = { app = "t3-probe" }
  }
  spec {
    replicas = 1
    selector {
      match_labels = { app = "t3-probe" }
    }
    template {
      metadata {
        labels = { app = "t3-probe" }
        annotations = {
          "checksum/probe" = sha256(file("${path.module}/probe.py"))
        }
      }
      spec {
        container {
          name  = "probe"
          image = "python:3.12-alpine"
          # Long-running pod, not a high-cadence CronJob: a one-time pinned
          # pip install at start (with retries against transient DNS) is the
          # lightweight alternative to owning a registry image for ~200 lines.
          command = ["sh", "-c", <<-EOT
            for i in 1 2 3 4 5; do
              pip install --no-cache-dir --quiet aiohttp==3.9.5 prometheus-client==0.20.0 && break
              echo "pip attempt $i failed; retrying" >&2; sleep 10
            done
            exec python /app/probe.py
          EOT
          ]
          port {
            container_port = 9108
            name           = "metrics"
          }
          volume_mount {
            name       = "app"
            mount_path = "/app"
            read_only  = true
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "192Mi"
            }
          }
        }
        volume {
          name = "app"
          config_map {
            name = kubernetes_config_map_v1.t3_probe.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
  }
}

resource "kubernetes_service" "t3_probe" {
  metadata {
    name      = "t3-probe"
    namespace = kubernetes_namespace.t3code.metadata[0].name
    labels    = { app = "t3-probe" }
  }
  spec {
    selector = { app = "t3-probe" }
    port {
      name        = "metrics"
      port        = 9108
      target_port = 9108
    }
  }
}
