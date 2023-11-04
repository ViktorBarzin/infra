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
          image = "redis/redis-stack"
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
resource "kubernetes_ingress_v1" "redis" {
  metadata {
    name      = "redis"
    namespace = "redis"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
      "nginx.ingress.kubernetes.io/auth-url" : "https://oauth2.viktorbarzin.me/oauth2/auth"
      "nginx.ingress.kubernetes.io/auth-signin" : "https://oauth2.viktorbarzin.me/oauth2/start?rd=/redirect/$http_host$escaped_request_uri"
    }
  }

  spec {
    tls {
      hosts       = ["redis.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "redis.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "redis"
              port {
                number = 8001
              }
            }
          }
        }
      }
    }
  }
}
