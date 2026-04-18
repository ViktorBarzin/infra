variable "tls_secret_name" {
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

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "n8n-secrets"
      namespace = "n8n"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "n8n-secrets"
      }
      dataFrom = [{
        extract = {
          key = "n8n"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.n8n]
}

resource "kubernetes_manifest" "external_secret_claude_agent" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "claude-agent-token"
      namespace = "n8n"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "claude-agent-token"
      }
      data = [{
        secretKey = "api_bearer_token"
        remoteRef = {
          key      = "claude-agent-service"
          property = "api_bearer_token"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.n8n]
}

resource "kubernetes_persistent_volume_claim" "data_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "n8n-data-encrypted"
    namespace = kubernetes_namespace.n8n.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted"
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
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
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
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
        annotations = {
          "diun.enable"                    = "true"
          "diun.include_tags"              = "^\\d+\\.\\d+\\.\\d+$"
          "dependency.kyverno.io/wait-for" = "postgresql.dbaas:5432"
        }
      }
      spec {
        service_account_name = kubernetes_service_account.n8n.metadata[0].name
        container {
          name  = "n8n"
          image = "docker.n8n.io/n8nio/n8n:1.80.0"
          env {
            name  = "N8N_PORT"
            value = "5678"
          }
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
            name = "DB_POSTGRESDB_PASSWORD"
            value_from {
              secret_key_ref {
                name = "n8n-secrets"
                key  = "db_password"
              }
            }
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
          env {
            name = "CLAUDE_AGENT_API_TOKEN"
            value_from {
              secret_key_ref {
                name = "claude-agent-token"
                key  = "api_bearer_token"
              }
            }
          }
          env {
            name  = "N8N_BLOCK_ENV_ACCESS_IN_NODE"
            value = "false"
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
              memory = "1Gi"
            }
            limits = {
              memory = "1Gi"
            }
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data_encrypted.metadata[0].name
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
  dns_type        = "proxied"
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
