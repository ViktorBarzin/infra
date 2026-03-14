variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "n8n_postgresql_password" {
  type      = string
  sensitive = true
}
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

module "nfs_data" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "n8n-data"
  namespace  = kubernetes_namespace.n8n.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/n8n"
}

# --- RBAC: Allow n8n to exec into OpenClaw pods for task execution ---

resource "kubernetes_service_account" "n8n" {
  metadata {
    name      = "n8n"
    namespace = kubernetes_namespace.n8n.metadata[0].name
  }
}

resource "kubernetes_role" "n8n_openclaw_exec" {
  metadata {
    name      = "n8n-openclaw-exec"
    namespace = "openclaw"
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods/exec"]
    verbs      = ["create"]
  }
}

resource "kubernetes_role_binding" "n8n_openclaw_exec" {
  metadata {
    name      = "n8n-openclaw-exec"
    namespace = "openclaw"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.n8n.metadata[0].name
    namespace = kubernetes_namespace.n8n.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.n8n_openclaw_exec.metadata[0].name
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
        service_account_name = kubernetes_service_account.n8n.metadata[0].name
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
              memory = "512Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = module.nfs_data.claim_name
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
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "n8n"
    "gethomepage.dev/description"  = "Workflow automation"
    "gethomepage.dev/icon"         = "n8n.png"
    "gethomepage.dev/group"        = "Automation"
    "gethomepage.dev/pod-selector" = ""
  }
}
