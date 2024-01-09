variable "tls_secret_name" {}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "uptime-kuma"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_namespace" "uptime-kuma" {
  metadata {
    name = "uptime-kuma"
    labels = {
      "istio-injection" : "enabled"
    }
  }
}

resource "kubernetes_deployment" "uptime-kuma" {
  metadata {
    name      = "uptime-kuma"
    namespace = "uptime-kuma"
    labels = {
      app = "uptime-kuma"
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "uptime-kuma"
      }
    }
    template {
      metadata {
        labels = {
          app = "uptime-kuma"
        }
      }
      spec {
        container {
          image = "louislam/uptime-kuma:latest"
          name  = "uptime-kuma"

          port {
            container_port = 3001
          }
          volume_mount {
            name       = "data"
            mount_path = "/app/data"
          }
        }
        volume {
          name = "data"
          nfs {
            server = "10.0.10.15"
            path   = "/mnt/main/uptime-kuma"
          }
        }
      }
    }
  }
}
resource "kubernetes_service" "uptime-kuma" {
  metadata {
    name      = "uptime-kuma"
    namespace = "uptime-kuma"
    labels = {
      "app" = "uptime-kuma"
    }
  }

  spec {
    selector = {
      app = "uptime-kuma"
    }
    port {
      port        = "80"
      target_port = "3001"
    }
  }
}
resource "kubernetes_ingress_v1" "uptime-kuma" {
  metadata {
    name      = "uptime-kuma"
    namespace = "uptime-kuma"
    annotations = {
      "kubernetes.io/ingress.class"                     = "nginx"
      "nginx.ingress.kubernetes.io/affinity"            = "cookie"
      "nginx.ingress.kubernetes.io/affinity-mode"       = "persistent"
      "nginx.ingress.kubernetes.io/session-cookie-name" = "_sa_nginx"
    }
  }

  spec {
    tls {
      hosts       = ["uptime.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "uptime.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "uptime-kuma"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}
