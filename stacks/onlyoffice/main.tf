variable "tls_secret_name" { type = string }
variable "onlyoffice_db_password" { type = string }
variable "onlyoffice_jwt_token" { type = string }
variable "nfs_server" { type = string }
variable "redis_host" { type = string }
variable "mysql_host" { type = string }


resource "kubernetes_namespace" "onlyoffice" {
  metadata {
    name = "onlyoffice"
    labels = {
      "istio-injection" : "disabled"
      tier                                           = local.tiers.edge
      "goldilocks.fairwinds.com/vpa-update-mode" = "off"
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.onlyoffice.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "onlyoffice-document-server" {
  metadata {
    name      = "onlyoffice-document-server"
    namespace = kubernetes_namespace.onlyoffice.metadata[0].name
    labels = {
      app  = "onlyoffice-document-server"
      tier = local.tiers.edge
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "onlyoffice-document-server"
      }
    }
    template {
      metadata {
        labels = {
          app = "onlyoffice-document-server"
        }
      }
      spec {
        container {
          name  = "onlyoffice-document-server"
          image = "onlyoffice/documentserver:8.2.3"
          resources {
            requests = {
              cpu    = "100m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "2"
              memory = "4Gi"
            }
          }
          port {
            name           = "http"
            container_port = 80
            protocol       = "TCP"
          }
          env {
            name  = "DB_TYPE"
            value = "mariadb"
          }
          env {
            name  = "DB_HOST"
            value = var.mysql_host
          }
          env {
            name  = "DB_PORT"
            value = 3306
          }
          env {
            name  = "DB_NAME"
            value = "onlyoffice"
          }
          env {
            name  = "DB_USER"
            value = "onlyoffice"
          }
          env {
            name  = "DB_PWD"
            value = var.onlyoffice_db_password
          }
          env {
            name  = "REDIS_SERVER_HOST"
            value = var.redis_host
          }
          env {
            name  = "REDIS_SERVER_PORT"
            value = 6379
          }
          env {
            name  = "JWT_SECRET"
            value = var.onlyoffice_jwt_token
          }

          volume_mount {
            name       = "data"
            mount_path = "/var/www/onlyoffice/Data"
          }
        }
        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/onlyoffice"
            server = var.nfs_server
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "onlyoffice" {
  metadata {
    name      = "onlyoffice-document-server"
    namespace = kubernetes_namespace.onlyoffice.metadata[0].name
    labels = {
      "app" = "onlyoffice-document-server"
    }
  }

  spec {
    selector = {
      app = "onlyoffice-document-server"
    }
    port {
      port = "80"
    }
  }
}
module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.onlyoffice.metadata[0].name
  name            = "onlyoffice"
  service_name    = "onlyoffice-document-server"
  tls_secret_name = var.tls_secret_name
}
