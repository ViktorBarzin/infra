variable "tls_secret_name" {}
variable "tier" { type = string }

resource "kubernetes_namespace" "changedetection" {
  metadata {
    name = "changedetection"
    labels = {
      "istio-injection" : "disabled"
      tier = var.tier
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.changedetection.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "changedetection" {
  metadata {
    name      = "changedetection"
    namespace = kubernetes_namespace.changedetection.metadata[0].name
    labels = {
      app  = "changedetection"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "changedetection"
      }
    }
    template {
      metadata {
        labels = {
          app = "changedetection"
        }
      }
      spec {
        container {
          name              = "sockpuppetbrowser"
          image             = "dgtlmoon/sockpuppetbrowser:latest"
          image_pull_policy = "IfNotPresent"
          port {
            name           = "ws"
            container_port = 3000
            protocol       = "TCP"
          }
          security_context {
            capabilities {
              add = ["SYS_ADMIN"]
            }
          }
        }

        container {
          name  = "changedetection"
          image = "ghcr.io/dgtlmoon/changedetection.io:latest" # latest is latest stable
          env {
            name  = "PLAYWRIGHT_DRIVER_URL"
            value = "ws://localhost:3000"
          }
          env {
            name  = "BASE_URL"
            value = "https://changedetection.viktorbarzin.me"
          }
          env {
            name  = "LOGGER_LEVEL"
            value = "WARNING"
          }
          env {
            name  = "TZ"
            value = "Europe/Sofia"
          }
          volume_mount {
            name       = "data"
            mount_path = "/datastore"
          }
          port {
            name           = "http"
            container_port = 5000
            protocol       = "TCP"
          }
        }
        # security_context {
        #   fs_group = "1500"
        # }
        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/changedetection"
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "changedetection" {
  metadata {
    name      = "changedetection"
    namespace = kubernetes_namespace.changedetection.metadata[0].name
    labels = {
      "app" = "changedetection"
    }
  }

  spec {
    selector = {
      app = "changedetection"
    }
    port {
      port        = 80
      target_port = 5000
    }
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.changedetection.metadata[0].name
  name            = "changedetection"
  tls_secret_name = var.tls_secret_name
  protected       = true
}
