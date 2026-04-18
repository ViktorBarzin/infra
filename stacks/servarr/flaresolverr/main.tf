variable "tls_secret_name" {}
variable "tier" { type = string }

resource "kubernetes_deployment" "flaresolverr" {
  metadata {
    name      = "flaresolverr"
    namespace = "servarr"
    labels = {
      app  = "flaresolverr"
      tier = var.tier
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "flaresolverr"
      }
    }
    template {
      metadata {
        labels = {
          app = "flaresolverr"
        }
      }
      spec {
        container {
          image = "ghcr.io/flaresolverr/flaresolverr:latest"
          name  = "flaresolverr"

          resources {
            requests = {
              cpu    = "10m"
              memory = "512Mi"
            }
            limits = {
              memory = "1Gi"
            }
          }
          port {
            container_port = 8191
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

resource "kubernetes_service" "flaresolverr" {
  metadata {
    name      = "flaresolverr"
    namespace = "servarr"
    labels = {
      app = "flaresolverr"
    }
  }

  spec {
    selector = {
      app = "flaresolverr"
    }
    port {
      name        = "http"
      target_port = 8191
      port        = 80
    }
  }
}

module "ingress" {
  source          = "../../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = "servarr"
  name            = "flaresolverr"
  tls_secret_name = var.tls_secret_name
  protected       = true
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "FlareSolverr"
    "gethomepage.dev/description"  = "Captcha solver proxy"
    "gethomepage.dev/icon"         = "flaresolverr.png"
    "gethomepage.dev/group"        = "Media & Entertainment"
    "gethomepage.dev/pod-selector" = ""
  }
}
