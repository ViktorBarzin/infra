variable "tls_secret_name" {}
variable "db_password" {}

resource "kubernetes_namespace" "paperless-ngx" {
  metadata {
    name = "paperless-ngx"
    # labels = {
    #   "istio-injection" : "enabled"
    # }
  }
}
module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "paperless-ngx"
  tls_secret_name = var.tls_secret_name
}


resource "kubernetes_deployment" "paperless-ngx" {
  metadata {
    name      = "paperless-ngx"
    namespace = "paperless-ngx"
    labels = {
      app = "paperless-ngx"
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
        app = "paperless-ngx"
      }
    }
    template {
      metadata {
        labels = {
          app = "paperless-ngx"
        }
      }
      spec {
        container {
          image = "paperlessngx/paperless-ngx:2.9"
          name  = "paperless-ngx"
          env {
            name  = "PAPERLESS_REDIS"
            value = "redis://redis.redis"
          }
          env {
            name  = "PAPERLESS_REDIS_PREFIX"
            value = "paperless-ngx"
          }
          env {
            name  = "PAPERLESS_DBENGINE"
            value = "mariadb"
          }
          env {
            name  = "PAPERLESS_DBHOST"
            value = "mysql.dbaas"
          }
          env {
            name  = "PAPERLESS_DBNAME"
            value = "paperless-ngx"
          }
          env {
            name  = "PAPERLESS_DBUSER"
            value = "paperless-ngx"
          }
          env {
            name  = "PAPERLESS_DBPASS"
            value = var.db_password
          }
          env {
            name  = "PAPERLESS_CSRF_TRUSTED_ORIGINS"
            value = "https://paperless-ngx.viktorbarzin.me,https://pdf.viktorbarzin.me"
          }
          env {
            name  = "PAPERLESS_DEBUG"
            value = "false"
          }
          env {
            name  = "PAPERLESS_MEDIA_ROOT"
            value = "../data"
          }
          env {
            name  = "PAPERLESS_OCR_USER_ARGS"
            value = "{\"invalidate_digital_signatures\": true}"
          }
          volume_mount {
            name       = "data"
            mount_path = "/usr/src/paperless/data"
          }

          port {
            container_port = 8000
          }
        }
        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/paperless-ngx"
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "paperless-ngx" {
  metadata {
    name      = "paperless-ngx"
    namespace = "paperless-ngx"
    labels = {
      "app" = "paperless-ngx"
    }
  }

  spec {
    selector = {
      app = "paperless-ngx"
    }
    port {
      name        = "http"
      target_port = 8000
      port        = 80
      protocol    = "TCP"
    }
  }
}


resource "kubernetes_ingress_v1" "paperless-ngx" {
  metadata {
    name      = "paperless-ngx"
    namespace = "paperless-ngx"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
      "nginx.ingress.kubernetes.io/proxy-body-size" : "100000m"
      # see https://github.com/kubernetes/ingress-nginx/blob/main/docs/user-guide/nginx-configuration/annotations.md#rate-limiting for all annotations
      # "nginx.ingress.kubernetes.io/limit-rpm": "5"
    }
  }

  spec {
    tls {
      hosts       = ["paperless-ngx.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "paperless-ngx.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "paperless-ngx"
              port {
                number = 8000
              }
            }
          }
        }
      }
    }
    rule {
      host = "pdf.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "paperless-ngx"
              port {
                number = 8000
              }
            }
          }
        }
      }
    }
  }
}
