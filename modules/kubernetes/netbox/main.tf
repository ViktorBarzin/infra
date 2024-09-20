variable "tls_secret_name" {}

resource "kubernetes_namespace" "netbox" {
  metadata {
    name = "netbox"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "netbox"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "netbox" {
  metadata {
    name      = "netbox"
    namespace = "netbox"
    labels = {
      app = "netbox"
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "netbox"
      }
    }
    template {
      metadata {
        annotations = {
          "diun.enable" = "true"
        }
        labels = {
          app = "netbox"
        }
      }
      spec {
        container {
          image = "lscr.io/linuxserver/netbox:v4.0.9-ls219"
          name  = "netbox"
          env {
            name  = "DB_USER"
            value = "netbox"
          }
          env {
            name  = "DB_PASSWORD"
            value = "ttPSBjF9oPLb49XZst3sGF"
          }
          env {
            name  = "DB_HOST"
            value = "postgresql.dbaas.svc.cluster.local"
          }
          env {
            name  = "REDIS_HOST"
            value = "redis.redis"
          }
          env {
            name  = "ALLOWED_HOST"
            value = "netbox.viktorbarzin.me"
          }
          env {
            name  = "SUPERUSER_EMAIL"
            value = "me@viktorbarzin.me"
          }
          env {
            name  = "SUPERUSER_PASSWORD"
            value = "ttPSBjF9oPLb49XZst3sGFasdf"
          }
          env {
            name  = "REMOTE_AUTH_ENABLED"
            value = "True"
          }
          env {
            name  = "REMOTE_AUTH_AUTO_CREATE_USER"
            value = "True"
          }

          env {
            name  = "PUID"
            value = 1000
          }
          env {
            name  = "PGID"
            value = 1000
          }
          env {
            name  = "TZ"
            value = "Europe/Sofia"
          }

          port {
            container_port = 8000
          }
          #   volume_mount {
          #     name       = "data"
          #     mount_path = "/books"
          #   }
        }
        # volume {
        #   name = "data"
        #   nfs {
        #     path   = "/mnt/main/netbox"
        #     server = "10.0.10.15"
        #   }
        # }
      }
    }
  }
}
resource "kubernetes_service" "netbox" {
  metadata {
    name      = "netbox"
    namespace = "netbox"
    labels = {
      "app" = "netbox"
    }
  }

  spec {
    selector = {
      app = "netbox"
    }
    port {
      name        = "http"
      target_port = 8000
      port        = 80
      protocol    = "TCP"
    }
  }
}
resource "kubernetes_ingress_v1" "netbox" {
  metadata {
    name      = "netbox"
    namespace = "netbox"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
      #   "nginx.ingress.kubernetes.io/proxy-body-size" : "5000m"
      "nginx.ingress.kubernetes.io/auth-url" : "https://oauth2.viktorbarzin.me/oauth2/auth"
      "nginx.ingress.kubernetes.io/auth-signin" : "https://oauth2.viktorbarzin.me/oauth2/start?rd=/redirect/$http_host$escaped_request_uri"
    }
  }

  spec {
    tls {
      hosts       = ["netbox.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "netbox.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "netbox"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
    rule {
      host = "books.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "netbox"
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

