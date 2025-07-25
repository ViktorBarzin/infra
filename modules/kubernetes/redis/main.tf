variable "tls_secret_name" {}

resource "kubernetes_namespace" "redis" {
  metadata {
    name = "redis"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "redis"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "redis" {
  metadata {
    name      = "redis"
    namespace = "redis"
    labels = {
      app = "redis"
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "redis"
      }
    }
    template {
      metadata {
        labels = {
          app = "redis"
        }
      }
      spec {
        container {
          image = "redis/redis-stack:7.4.0-v6"
          name  = "redis"

          port {
            container_port = 6379
          }
          port {
            container_port = 8001
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
        }
        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/redis"
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}
resource "kubernetes_service" "redis" {
  metadata {
    name      = "redis"
    namespace = "redis"
    labels = {
      app = "redis"
    }
  }

  spec {
    selector = {
      app = "redis"
    }
    port {
      name = "redis"
      port = 6379
    }
    port {
      name = "http"
      port = 8001
    }
  }
}
module "ingress" {
  source          = "../ingress_factory"
  namespace       = "redis"
  name            = "redis"
  tls_secret_name = var.tls_secret_name
  protected       = true
  port            = 8001
}
