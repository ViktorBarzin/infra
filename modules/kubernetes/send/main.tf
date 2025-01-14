variable "tls_secret_name" {}

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
  namespace       = "send"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "send" {
  metadata {
    name      = "send"
    namespace = "send"
    labels = {
      app = "send"
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
    namespace = "send"
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
  namespace       = "send"
  name            = "send"
  tls_secret_name = var.tls_secret_name
  port            = 1443
  extra_annotations = {
    "nginx.ingress.kubernetes.io/client-max-body-size" : "0"
    "nginx.ingress.kubernetes.io/proxy-body-size" : "0",
  }
}
