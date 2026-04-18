data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "claude-agent-service"
}

data "vault_kv_secret_v2" "ci_secrets" {
  mount = "secret"
  name  = "ci/infra"
}

data "vault_kv_secret_v2" "viktor_secrets" {
  mount = "secret"
  name  = "viktor"
}

locals {
  namespace = "claude-agent"
  image     = "registry.viktorbarzin.me/claude-agent-service"
  image_tag = "382d6b14"
  labels = {
    app = "claude-agent-service"
  }
}

# --- Namespace ---

resource "kubernetes_namespace" "claude_agent" {
  metadata {
    name = local.namespace
    labels = {
      tier                                    = local.tiers.aux
      "resource-governance/custom-limitrange" = "true"
      "resource-governance/custom-quota"      = "true"
    }
  }
}

# --- Secrets ---

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "claude-agent-secrets"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "claude-agent-secrets"
      }
      data = [
        {
          secretKey = "GITHUB_TOKEN"
          remoteRef = {
            key      = "viktor"
            property = "github_pat"
          }
        },
        {
          secretKey = "API_BEARER_TOKEN"
          remoteRef = {
            key      = "claude-agent-service"
            property = "api_bearer_token"
          }
        },
        {
          # Long-lived OAuth token (1-year) from `claude setup-token`.
          # Preferred over the short-lived .credentials.json — CLI picks this up and
          # skips the refresh flow entirely. Rotate yearly; alert 30d before expiry.
          secretKey = "CLAUDE_CODE_OAUTH_TOKEN"
          remoteRef = {
            key      = "claude-agent-service"
            property = "claude_oauth_token"
          }
        },
      ]
    }
  }
  depends_on = [kubernetes_namespace.claude_agent]
}

# SSH key for git operations (kept for fallback)
resource "kubernetes_secret" "ssh_key" {
  metadata {
    name      = "ssh-key"
    namespace = kubernetes_namespace.claude_agent.metadata[0].name
  }
  data = {
    "id_rsa" = data.vault_kv_secret_v2.ci_secrets.data["devvm_ssh_key"]
  }
  type = "Opaque"
}

# SOPS age key for terraform state decryption
resource "kubernetes_secret" "sops_age_key" {
  metadata {
    name      = "sops-age-key"
    namespace = kubernetes_namespace.claude_agent.metadata[0].name
  }
  data = {
    "keys.txt" = data.vault_kv_secret_v2.viktor_secrets.data["sops_age_key_devvm"]
  }
  type = "Opaque"
}

# Claude OAuth credentials (for claude -p)
resource "kubernetes_secret" "claude_credentials" {
  metadata {
    name      = "claude-credentials"
    namespace = kubernetes_namespace.claude_agent.metadata[0].name
  }
  data = {
    ".credentials.json" = data.vault_kv_secret_v2.secrets.data["claude_credentials_json"]
  }
  type = "Opaque"
}

# git-crypt key for repo decryption
resource "kubernetes_config_map" "git_crypt_key" {
  metadata {
    name      = "git-crypt-key"
    namespace = kubernetes_namespace.claude_agent.metadata[0].name
  }
  binary_data = {
    "key" = filebase64("${path.root}/../../.git/git-crypt/keys/default")
  }
}

# --- RBAC ---

resource "kubernetes_service_account" "claude_agent" {
  metadata {
    name      = "claude-agent"
    namespace = kubernetes_namespace.claude_agent.metadata[0].name
  }
}

resource "kubernetes_cluster_role" "claude_agent" {
  metadata {
    name = "claude-agent"
  }

  rule {
    verbs      = ["get", "list", "watch"]
    api_groups = ["", "apps", "batch"]
    resources  = ["pods", "pods/log", "nodes", "events", "deployments", "services", "namespaces", "jobs", "cronjobs", "configmaps", "replicasets", "statefulsets", "daemonsets"]
  }

  rule {
    verbs      = ["patch", "update"]
    api_groups = ["apps"]
    resources  = ["deployments"]
  }

  rule {
    verbs      = ["create"]
    api_groups = [""]
    resources  = ["pods/exec"]
  }
}

resource "kubernetes_cluster_role_binding" "claude_agent" {
  metadata {
    name = "claude-agent"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.claude_agent.metadata[0].name
    namespace = kubernetes_namespace.claude_agent.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.claude_agent.metadata[0].name
  }
}

# --- Storage ---

resource "kubernetes_persistent_volume_claim" "workspace" {
  wait_until_bound = false
  metadata {
    name      = "claude-agent-workspace-encrypted"
    namespace = kubernetes_namespace.claude_agent.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "20Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted"
    resources {
      requests = {
        storage = "10Gi"
      }
    }
  }
}

# --- Deployment ---

resource "kubernetes_deployment" "claude_agent" {
  metadata {
    name      = "claude-agent-service"
    namespace = kubernetes_namespace.claude_agent.metadata[0].name
    labels    = local.labels
  }

  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = local.labels
    }

    template {
      metadata {
        labels = local.labels
      }

      spec {
        service_account_name = kubernetes_service_account.claude_agent.metadata[0].name

        image_pull_secrets {
          name = "registry-credentials"
        }

        security_context {
          run_as_user  = 1000
          run_as_group = 1000
          fs_group     = 1000
        }

        # Fix workspace ownership (PVC may have root-owned files from prior run)
        init_container {
          name    = "fix-perms"
          image   = "busybox:1.37"
          command = ["sh", "-c", "chown -R 1000:1000 /workspace"]
          security_context {
            run_as_user = 0
          }
          volume_mount {
            name       = "workspace"
            mount_path = "/workspace"
          }
          resources {
            requests = {
              memory = "32Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }
        }

        # Copy Claude credentials to writable volume (CLI needs to refresh OAuth tokens)
        init_container {
          name    = "copy-claude-creds"
          image   = "busybox:1.37"
          command = ["sh", "-c", "cp /secrets/claude/.credentials.json /home/agent/.claude/.credentials.json && chown 1000:1000 /home/agent/.claude/.credentials.json"]
          security_context {
            run_as_user = 0
          }
          volume_mount {
            name       = "claude-credentials-secret"
            mount_path = "/secrets/claude"
          }
          volume_mount {
            name       = "claude-home"
            mount_path = "/home/agent/.claude"
          }
          resources {
            requests = {
              memory = "32Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }
        }

        # Init: clone repo + unlock git-crypt on first run
        init_container {
          name  = "git-init"
          image = "${local.image}:${local.image_tag}"
          command = ["sh", "-c", <<-EOF
            set -e

            # Configure git with HTTPS + PAT
            git config --global user.name "Claude Agent Service"
            git config --global user.email "claude-agent@viktorbarzin.me"
            git config --global --add safe.directory /workspace/infra
            git config --global url."https://$${GITHUB_TOKEN}@github.com/".insteadOf "git@github.com:"
            git config --global url."https://$${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"

            # Clone or update repo
            if [ ! -d /workspace/infra/.git ]; then
              git clone https://$${GITHUB_TOKEN}@github.com/ViktorBarzin/infra.git /workspace/infra
            else
              cd /workspace/infra
              git fetch origin
              git reset --hard origin/master
            fi

            # Unlock git-crypt
            cd /workspace/infra
            git-crypt unlock /secrets/git-crypt/key || true
          EOF
          ]

          env_from {
            secret_ref {
              name = "claude-agent-secrets"
            }
          }

          volume_mount {
            name       = "workspace"
            mount_path = "/workspace"
          }
          volume_mount {
            name       = "git-crypt-key"
            mount_path = "/secrets/git-crypt"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }

        container {
          name  = "claude-agent-service"
          image = "${local.image}:${local.image_tag}"

          port {
            container_port = 8080
          }

          env_from {
            secret_ref {
              name = "claude-agent-secrets"
            }
          }

          env {
            name  = "WORKSPACE_DIR"
            value = "/workspace/infra"
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 10
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          volume_mount {
            name       = "workspace"
            mount_path = "/workspace"
          }
          volume_mount {
            name       = "sops-age-key"
            mount_path = "/home/agent/.config/sops/age"
          }
          volume_mount {
            name       = "claude-home"
            mount_path = "/home/agent/.claude"
          }

          resources {
            requests = {
              cpu    = "500m"
              memory = "2Gi"
            }
            limits = {
              memory = "4Gi"
            }
          }
        }

        volume {
          name = "workspace"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.workspace.metadata[0].name
          }
        }

        volume {
          name = "sops-age-key"
          secret {
            secret_name  = kubernetes_secret.sops_age_key.metadata[0].name
            default_mode = "0600"
          }
        }

        volume {
          name = "git-crypt-key"
          config_map {
            name = kubernetes_config_map.git_crypt_key.metadata[0].name
          }
        }

        volume {
          name = "claude-credentials-secret"
          secret {
            secret_name  = kubernetes_secret.claude_credentials.metadata[0].name
            default_mode = "0600"
          }
        }

        volume {
          name = "claude-home"
          empty_dir {}
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}

# --- Service ---

resource "kubernetes_service" "claude_agent" {
  metadata {
    name      = "claude-agent-service"
    namespace = kubernetes_namespace.claude_agent.metadata[0].name
    labels    = local.labels
  }

  spec {
    selector = local.labels

    port {
      port        = 8080
      target_port = 8080
    }

    type = "ClusterIP"
  }
}
