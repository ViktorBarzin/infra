variable "tls_secret_name" { type = string }
variable "paperless_db_password" { type = string }
variable "homepage_credentials" { type = map(any) }
variable "nfs_server" { type = string }
variable "redis_host" { type = string }
variable "mysql_host" { type = string }


resource "kubernetes_namespace" "paperless-ngx" {
  metadata {
    name = "paperless-ngx"
    labels = {
      tier = local.tiers.edge
    }
    # labels = {
    #   "istio-injection" : "enabled"
    # }
  }
}
module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.paperless-ngx.metadata[0].name
  tls_secret_name = var.tls_secret_name
}


resource "kubernetes_deployment" "paperless-ngx" {
  metadata {
    name      = "paperless-ngx"
    namespace = kubernetes_namespace.paperless-ngx.metadata[0].name
    labels = {
      app  = "paperless-ngx"
      tier = local.tiers.edge
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
        annotations = {
          "diun.enable"       = "false"
          "diun.include_tags" = "^\\d+(?:\\.\\d+)?(?:\\.\\d+)?$"
        }
      }
      spec {
        container {
          image = "ghcr.io/paperless-ngx/paperless-ngx:latest"
          name  = "paperless-ngx"
          env {
            name = "PAPERLESS_REDIS"
            // If redis gets stuck, try deleting the locks files in log dir
            value = "redis://${var.redis_host}"
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
            value = var.mysql_host
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
            value = var.paperless_db_password
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

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "2"
              memory = "1Gi"
            }
          }

          port {
            container_port = 8000
          }
        }
        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/paperless-ngx"
            server = var.nfs_server
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "paperless-ngx" {
  metadata {
    name      = "paperless-ngx"
    namespace = kubernetes_namespace.paperless-ngx.metadata[0].name
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

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.paperless-ngx.metadata[0].name
  name            = "paperless-ngx"
  service_name    = "paperless-ngx"
  host            = "pdf"
  tls_secret_name = var.tls_secret_name
  port            = 80
  extra_annotations = {
    "gethomepage.dev/enabled"     = "true"
    "gethomepage.dev/description" = "Document library"
    # gethomepage.dev/group: Media
    "gethomepage.dev/icon" : "paperless-ngx.png"
    "gethomepage.dev/name"        = "Paperless-ngx"
    "gethomepage.dev/widget.type" = "paperlessngx"
    "gethomepage.dev/widget.url"  = "https://pdf.viktorbarzin.me"
    # "gethomepage.dev/widget.token"    = var.homepage_token
    "gethomepage.dev/widget.username" = var.homepage_credentials["paperless-ngx"]["username"]
    "gethomepage.dev/widget.password" = var.homepage_credentials["paperless-ngx"]["password"]
    "gethomepage.dev/widget.fields"   = "[\"total\"]"
    "gethomepage.dev/pod-selector"    = ""
    # gethomepage.dev/weight: 10 # optional
    # gethomepage.dev/instance: "public" # optional
  }
  rybbit_site_id = "be6d140cbed8"
}
