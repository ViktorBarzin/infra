variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
variable "postgresql_host" { type = string }
variable "woodpecker_forgejo_url" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "woodpecker"
}

data "vault_kv_secret_v2" "platform" {
  mount = "secret"
  name  = "platform"
}

locals {
  k8s_users = jsondecode(data.vault_kv_secret_v2.platform.data["k8s_users"])

  # Build admin list: existing admin + all namespace-owner usernames
  woodpecker_admins = join(",", concat(
    ["ViktorBarzin"],
    [for name, user in local.k8s_users : name if user.role == "namespace-owner"]
  ))
}

resource "kubernetes_namespace" "woodpecker" {
  metadata {
    name = "woodpecker"
    labels = {
      "resource-governance/custom-quota" = "true"
      tier                               = local.tiers.edge
    }
  }
}

resource "kubernetes_resource_quota" "woodpecker" {
  metadata {
    name      = "tier-quota"
    namespace = kubernetes_namespace.woodpecker.metadata[0].name
  }
  spec {
    hard = {
      "requests.cpu"    = "16"
      "requests.memory" = "16Gi"
      "limits.memory"   = "32Gi"
      pods              = "60"
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.woodpecker.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "woodpecker-secrets"
      namespace = "woodpecker"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "woodpecker-secrets"
      }
      dataFrom = [{
        extract = {
          key = "woodpecker"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.woodpecker]
}

# DB credentials from Vault database engine (rotated every 24h)
# ExternalSecret provides WOODPECKER_DATABASE_DATASOURCE injected via
# server.extraSecretNamesForEnvFrom — auto-updates when password rotates
resource "kubernetes_manifest" "db_external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "woodpecker-db-creds"
      namespace = "woodpecker"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "woodpecker-db-creds"
        template = {
          data = {
            WOODPECKER_DATABASE_DATASOURCE = "postgres://woodpecker:{{ .password }}@${var.postgresql_host}:5432/woodpecker?sslmode=disable"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/pg-woodpecker"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.woodpecker]
}

resource "kubernetes_config_map" "git_crypt_key" {
  metadata {
    name      = "git-crypt-key"
    namespace = kubernetes_namespace.woodpecker.metadata[0].name
  }

  data = {
    "key" = filebase64("${path.root}/../../.git/git-crypt/keys/default")
  }
}

# Database init job - REMOVED: database and user already exist.
# The job used -U root which doesn't work with CNPG (superuser is 'postgres').
# Vault DB engine manages the woodpecker credentials via rotation.

# Woodpecker server data is on local-path (node-local storage), NOT NFS.
# The old NFS PV was unused — PVC was already bound to local-path PV.
# No PV management needed here.

# Helm release for Woodpecker CI
# Database datasource is now injected from ExternalSecret via envFrom
resource "helm_release" "woodpecker" {
  name       = "woodpecker"
  namespace  = kubernetes_namespace.woodpecker.metadata[0].name
  repository = "oci://ghcr.io/woodpecker-ci/helm"
  chart      = "woodpecker"
  version    = "3.5.1"

  values = [
    templatefile("${path.module}/values.yaml", {
      github_client_id      = data.vault_kv_secret_v2.secrets.data["github_client_id"]
      github_client_secret  = data.vault_kv_secret_v2.secrets.data["github_client_secret"]
      agent_secret          = data.vault_kv_secret_v2.secrets.data["agent_secret"]
      forgejo_client_id     = data.vault_kv_secret_v2.secrets.data["forgejo_client_id"]
      forgejo_client_secret = data.vault_kv_secret_v2.secrets.data["forgejo_client_secret"]
      forgejo_url           = var.woodpecker_forgejo_url
      woodpecker_admins     = local.woodpecker_admins
    })
  ]

  timeout    = 600
  depends_on = [kubernetes_manifest.db_external_secret]
}

# ClusterRoleBinding - build pods need cluster-admin to PATCH deployments across namespaces
resource "kubernetes_cluster_role_binding" "woodpecker" {
  metadata {
    name = "woodpecker"
  }
  subject {
    kind      = "ServiceAccount"
    name      = "woodpecker-agent"
    namespace = kubernetes_namespace.woodpecker.metadata[0].name
  }
  role_ref {
    kind      = "ClusterRole"
    name      = "cluster-admin"
    api_group = "rbac.authorization.k8s.io"
  }
}

# Also bind the default SA (pipeline pods run as default)
resource "kubernetes_cluster_role_binding" "woodpecker_default" {
  metadata {
    name = "woodpecker-default"
  }
  subject {
    kind      = "ServiceAccount"
    name      = "default"
    namespace = kubernetes_namespace.woodpecker.metadata[0].name
  }
  role_ref {
    kind      = "ClusterRole"
    name      = "cluster-admin"
    api_group = "rbac.authorization.k8s.io"
  }
}

# --- Vault → Woodpecker Secret Sync ---
# Syncs secrets from Vault KV (secret/ci/global) to Woodpecker global secrets via API.
# Runs every 6 hours. Secrets are created/updated via Woodpecker REST API.

resource "kubernetes_config_map" "vault_woodpecker_sync" {
  metadata {
    name      = "vault-woodpecker-sync"
    namespace = kubernetes_namespace.woodpecker.metadata[0].name
  }

  data = {
    "sync.sh" = <<-SCRIPT
      #!/bin/sh
      set -e
      VAULT_ADDR="http://vault-active.vault.svc.cluster.local:8200"
      WP_API="http://woodpecker-server.woodpecker.svc.cluster.local/api"

      # Authenticate to Vault via K8s SA
      SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
      VAULT_TOKEN=$(curl -sf -X POST "$VAULT_ADDR/v1/auth/kubernetes/login" \
        -d "{\"role\":\"woodpecker-sync\",\"jwt\":\"$SA_TOKEN\"}" | jq -r .auth.client_token)

      if [ -z "$VAULT_TOKEN" ] || [ "$VAULT_TOKEN" = "null" ]; then
        echo "ERROR: Failed to authenticate to Vault"
        exit 1
      fi

      # Get Woodpecker API token from Vault
      WP_TOKEN=$(curl -sf -H "X-Vault-Token: $VAULT_TOKEN" \
        "$VAULT_ADDR/v1/secret/data/ci/global" | jq -r '.data.data.woodpecker_api_token // empty')

      if [ -z "$WP_TOKEN" ]; then
        echo "ERROR: No woodpecker_api_token in secret/ci/global"
        exit 1
      fi

      # Sync global secrets
      SECRETS=$(curl -sf -H "X-Vault-Token: $VAULT_TOKEN" \
        "$VAULT_ADDR/v1/secret/data/ci/global" | jq -r '.data.data | to_entries[] | select(.key != "woodpecker_api_token") | @base64')

      synced=0
      for entry in $SECRETS; do
        NAME=$(echo "$entry" | base64 -d | jq -r .key)
        VALUE=$(echo "$entry" | base64 -d | jq -r .value)

        # Try PATCH first (update), fall back to POST (create)
        STATUS=$(curl -sf -o /dev/null -w "%%{http_code}" -X PATCH "$WP_API/secrets/$NAME" \
          -H "Authorization: Bearer $WP_TOKEN" \
          -H "Content-Type: application/json" \
          -d "{\"name\":\"$NAME\",\"value\":\"$VALUE\",\"events\":[\"push\",\"tag\",\"deployment\"]}" 2>/dev/null || echo "000")

        if [ "$STATUS" != "200" ]; then
          curl -sf -X POST "$WP_API/secrets" \
            -H "Authorization: Bearer $WP_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{\"name\":\"$NAME\",\"value\":\"$VALUE\",\"events\":[\"push\",\"tag\",\"deployment\"]}" > /dev/null
        fi
        synced=$((synced + 1))
      done
      echo "Synced $synced global secrets from Vault to Woodpecker"
    SCRIPT
  }
}

resource "kubernetes_cron_job_v1" "vault_secret_sync" {
  metadata {
    name      = "vault-woodpecker-sync"
    namespace = kubernetes_namespace.woodpecker.metadata[0].name
  }
  spec {
    schedule                      = "0 */6 * * *"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    concurrency_policy            = "Forbid"
    job_template {
      metadata {}
      spec {
        template {
          metadata {}
          spec {
            container {
              name    = "sync"
              image   = "alpine"
              command = ["/bin/sh", "-c", "apk add --no-cache curl jq && /bin/sh /scripts/sync.sh"]
              volume_mount {
                name       = "sync-script"
                mount_path = "/scripts"
              }
              resources {
                requests = {
                  cpu    = "10m"
                  memory = "32Mi"
                }
                limits = {
                  memory = "64Mi"
                }
              }
            }
            volume {
              name = "sync-script"
              config_map {
                name = kubernetes_config_map.vault_woodpecker_sync.metadata[0].name
              }
            }
            restart_policy = "OnFailure"
          }
        }
      }
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.woodpecker.metadata[0].name
  name            = "ci"
  service_name    = "woodpecker-server"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Woodpecker CI"
    "gethomepage.dev/description"  = "CI/CD pipelines"
    "gethomepage.dev/icon"         = "woodpecker-ci.png"
    "gethomepage.dev/group"        = "Development & CI"
    "gethomepage.dev/pod-selector" = ""
  }
}
