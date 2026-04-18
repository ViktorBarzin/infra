# Contents for cloudflare tunnel

variable "tls_secret_name" {}
variable "cloudflare_tunnel_token" {}
resource "kubernetes_namespace" "cloudflared" {
  metadata {
    name = "cloudflared"
    labels = {
      tier = var.tier
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
          image   = "cloudflare/cloudflared"
          name    = "cloudflared"
          command = ["cloudflared", "tunnel", "run"]
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
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
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

