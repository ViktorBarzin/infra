variable "tls_secret_name" { type = string }
variable "n8n_postgresql_password" { type = string }
variable "nfs_server" { type = string }
variable "postgresql_host" { type = string }


module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.n8n.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_namespace" "n8n" {
  metadata {
    name = "n8n"
    labels = {
      tier = local.tiers.aux
    }
  }
}

resource "kubernetes_deployment" "n8n" {
  metadata {
    name      = "n8n"
    namespace = kubernetes_namespace.n8n.metadata[0].name
    labels = {
      app  = "n8n"
      tier = local.tiers.aux
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
          app = "n8n"
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
            value = var.postgresql_host
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
            value = var.n8n_postgresql_password
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
          resources {
            requests = {
              cpu    = "25m"
              memory = "256Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "1Gi"
            }
          }
        }
        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/n8n"
            server = var.nfs_server
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "n8n" {
  metadata {
    name      = "n8n"
    namespace = kubernetes_namespace.n8n.metadata[0].name
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
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.n8n.metadata[0].name
  name            = "n8n"
  tls_secret_name = var.tls_secret_name
}
