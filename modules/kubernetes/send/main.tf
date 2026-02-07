variable "tls_secret_name" {}
variable "tier" { type = string }

resource "kubernetes_namespace" "send" {
  metadata {
    name = "send"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.send.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "send" {
  metadata {
    name      = "send"
    namespace = kubernetes_namespace.send.metadata[0].name
    labels = {
      app  = "send"
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
        app = "send"
      }
    }
    template {
      metadata {
        labels = {
          app = "send"
        }
      }
      spec {
        container {
          image = "registry.gitlab.com/timvisee/send:latest"
          name  = "send"

          port {
            container_port = 1443
          }
          env {
            name  = "FILE_DIR"
            value = "/uploads"
          }
          env {
            name  = "BASE_URL"
            value = "https://send.viktorbarzin.me"
          }
          env {
            name  = "MAX_FILE_SIZE"
            value = "5368709120"
          }
          env {
            name  = "MAX_DOWNLOADS"
            value = 10 # try to minimize abusive behaviour
          }
          env {
            name  = "MAX_EXPIRE_SECONDS"
            value = 7 * 24 * 3600
          }
          env {
            name  = "REDIS_HOST"
            value = "redis.redis.svc.cluster.local"
          }
          volume_mount {
            name       = "data"
            mount_path = "/uploads"
          }
        }
        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/send"
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}
resource "kubernetes_service" "send" {
  metadata {
    name      = "send"
    namespace = kubernetes_namespace.send.metadata[0].name
    labels = {
      app = "send"
    }
  }

  spec {
    selector = {
      app = "send"
    }
    port {
      name = "http"
      port = 1443
    }
  }
}
module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.send.metadata[0].name
  name            = "send"
  tls_secret_name = var.tls_secret_name
  port            = 1443
  rybbit_site_id  = "c1b8f8aa831b"
}
