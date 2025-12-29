variable "tls_secret_name" {}
resource "kubernetes_namespace" "ntfy" {
  metadata {
    name = "ntfy"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.ntfy.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "ntfy" {
  metadata {
    name      = "ntfy"
    namespace = kubernetes_namespace.ntfy.metadata[0].name
    labels = {
      app = "ntfy"
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "RollingUpdate"
    }
    selector {
      match_labels = {
        app = "ntfy"
      }
    }
    template {
      metadata {
        labels = {
          app = "ntfy"
        }
      }
      spec {
        container {
          image = "binwiederhier/ntfy"
          name  = "ntfy"
          args  = ["serve"]

          port {
            container_port = 80
          }
          env {
            name  = "NTFY_BASE_URL"
            value = "https://ntfy.viktorbarzin.me"
          }
          env {
            name = "NTFY_UPSTREAM_BASE_URL"
            # value = "https://ntfy.viktorbarzin.me"
            value = "https://ntfy.sh"
          }
          env {
            name  = "NTFY_BEHIND_PROXY"
            value = true
          }
          env {
            name  = "NTFY_ENABLE_LOGIN"
            value = true
          }
          env {
            name  = "NTFY_AUTH_FILE"
            value = "/var/lib/ntfy/user.db"
          }
          env {
            name  = "NTFY_AUTH_DEFAULT_ACCESS"
            value = "deny-all"
          }
          env {
            name  = "NTFY_ENABLE_METRICS"
            value = true
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/ntfy/"
          }
        }
        volume {
          name = "data"
          nfs {
            server = "10.0.10.15"
            path   = "/mnt/main/ntfy"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "ntfy" {
  metadata {
    name      = "ntfy"
    namespace = kubernetes_namespace.ntfy.metadata[0].name
    labels = {
      "app" = "ntfy"
    }
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/path"   = "/metrics"
      "prometheus.io/port"   = "80"
    }
  }

  spec {
    selector = {
      app = "ntfy"
    }
    port {
      name        = "http"
      target_port = 80
      port        = 80
    }
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.ntfy.metadata[0].name
  name            = "ntfy"
  tls_secret_name = var.tls_secret_name
}

