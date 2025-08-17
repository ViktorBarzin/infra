variable "tls_secret_name" {}
variable "db_password" { type = string }
variable "jwt_token" { type = string }

resource "kubernetes_namespace" "onlyoffice" {
  metadata {
    name = "onlyoffice"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "onlyoffice"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "onlyoffice-document-server" {
  metadata {
    name      = "onlyoffice-document-server"
    namespace = "onlyoffice"
    labels = {
      app = "onlyoffice-document-server"
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
            value = "mysql.dbaas"
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
            value = var.db_password
          }
          env {
            name  = "REDIS_SERVER_HOST"
            value = "redis.redis"
          }
          env {
            name  = "REDIS_SERVER_PORT"
            value = 6379
          }
          env {
            name  = "JWT_SECRET"
            value = var.jwt_token
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
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "onlyoffice" {
  metadata {
    name      = "onlyoffice-document-server"
    namespace = "onlyoffice"
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
  source          = "../ingress_factory"
  namespace       = "onlyoffice"
  name            = "onlyoffice"
  service_name    = "onlyoffice-document-server"
  tls_secret_name = var.tls_secret_name
}
