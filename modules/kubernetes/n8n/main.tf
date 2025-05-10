variable "tls_secret_name" {}
variable "postgresql_password" {}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "n8n"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_namespace" "immich" {
  metadata {
    name = "n8n"
  }
}

resource "kubernetes_deployment" "n8n" {
  metadata {
    name      = "n8n"
    namespace = "n8n"
    labels = {
      app = "n8n"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "n8n"
      }
    }
    template {
      metadata {
        labels = {
          app                             = "n8n"
          "kubernetes.io/cluster-service" = "true"
        }
      }
      spec {
        container {
          name  = "n8n"
          image = "docker.n8n.io/n8nio/n8n"
          env {
            name  = "DB_TYPE"
            value = "postgresdb"
          }
          env {
            name  = "DB_POSTGRESDB_DATABASE"
            value = "n8n"
          }
          env {
            name  = "DB_POSTGRESDB_HOST"
            value = "postgresql.dbaas"
          }
          env {
            name  = "DB_POSTGRESDB_PORT"
            value = "5432"
          }
          env {
            name  = "DB_POSTGRESDB_USER"
            value = "n8n"
          }
          env {
            name  = "DB_POSTGRESDB_PASSWORD"
            value = var.postgresql_password
          }
          env {
            name  = "GENERIC_TIMEZONE"
            value = "Europe/Sofia"
          }
          env {
            name  = "TZ"
            value = "Europe/Sofia"
          }
          env {
            name  = "DOMAIN_NAME"
            value = "viktorbarzin.me"
          }
          env {
            name  = "DOMAIN_NAME"
            value = "n8n"
          }
          env {
            name  = "N8N_EDITOR_BASE_URL"
            value = "https://n8n.viktorbarzin.me"
          }
          env {
            name  = "WEBHOOK_URL"
            value = "https://n8n.viktorbarzin.me"
          }
          volume_mount {
            name       = "data"
            mount_path = "/home/node/.n8n"
          }
          port {
            name           = "http"
            container_port = 5678
            protocol       = "TCP"
          }
        }
        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/n8n"
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "n8n" {
  metadata {
    name      = "n8n"
    namespace = "n8n"
    labels = {
      "app" = "n8n"
    }
  }

  spec {
    selector = {
      app = "n8n"
    }
    port {
      port        = "80"
      target_port = "5678"
    }
  }
}
module "ingress" {
  source          = "../ingress_factory"
  namespace       = "n8n"
  name            = "n8n"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "nginx.ingress.kubernetes.io/proxy-body-size" : "20000m"
  }
}
