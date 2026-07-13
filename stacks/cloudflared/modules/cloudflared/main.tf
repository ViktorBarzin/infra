# Contents for cloudflare tunnel

variable "tls_secret_name" {}
variable "cloudflare_tunnel_token" {}
resource "kubernetes_namespace" "cloudflared" {
  metadata {
    name = "cloudflared"
    labels = {
      tier               = var.tier
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}
variable "tier" { type = string }

module "tls_secret" {
  source          = "../../../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.cloudflared.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "cloudflared" {
  metadata {
    name      = "cloudflared"
    namespace = kubernetes_namespace.cloudflared.metadata[0].name
    labels = {
      app  = "cloudflared"
      tier = var.tier
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 3
    strategy {
      type = "RollingUpdate"
    }
    selector {
      match_labels = {
        app = "cloudflared"
      }
    }
    template {
      metadata {
        labels = {
          app = "cloudflared"
        }
      }
      spec {
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector {
            match_labels = {
              app = "cloudflared"
            }
          }
        }
        container {
          # image = "wisdomsky/cloudflared-web:latest"
          image = "cloudflare/cloudflared"
          name  = "cloudflared"
          # --no-autoupdate: without it cloudflared self-updates in place and
          # exits (code 11) when CF ships a release, severing every WebSocket
          # riding the tunnel (observed as t3/terminal drops, 2026-06-09/10).
          # Image updates are handled by pod rollouts, not in-place binaries.
          command = ["cloudflared", "tunnel", "--no-autoupdate", "run"]
          env {
            name  = "TUNNEL_TOKEN"
            value = var.cloudflare_tunnel_token
          }

          port {
            container_port = 14333
          }
          resources {
            requests = {
              cpu    = "15m"
              memory = "128Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }
        dns_config {
          option {
            name  = "ndots"
            value = "2"
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    # KEEL_IGNORE_IMAGE: Keel bumps the cloudflared tag in-cluster via pod
    # rollout (image is the bare `cloudflare/cloudflared`, Keel-enrolled via the
    # label above). Without this, every apply reverts Keel's live pin (observed
    # 2026.7.1 -> bare/latest) and needlessly rolls the tunnel that fronts every
    # proxied service.
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,
      spec[0].template[0].spec[0].container[0].image,
    ]
  }
}

resource "kubernetes_pod_disruption_budget_v1" "cloudflared" {
  metadata {
    name      = "cloudflared"
    namespace = kubernetes_namespace.cloudflared.metadata[0].name
  }
  spec {
    max_unavailable = "1"
    selector {
      match_labels = {
        app = "cloudflared"
      }
    }
  }
}

resource "kubernetes_service" "cloudflared" {
  metadata {
    name      = "cloudflared"
    namespace = kubernetes_namespace.cloudflared.metadata[0].name
    labels = {
      "app" = "cloudflared"
    }
  }

  spec {
    selector = {
      app = "cloudflared"
    }
    port {
      name        = "http"
      target_port = 14333
      port        = 80
      protocol    = "TCP"
    }
  }
}

