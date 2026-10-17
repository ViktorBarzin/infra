# Secrets the Deployment reads.
#
# secret/<vault_kv_name> in Vault KV holds, seeded by hand before the first
# apply (CI's Vault role can read secret/* but not write it):
#   better_auth_secret  Better Auth's signing and encryption secret
#   oidc_client_id      the app slug, the client_id in authentik.tf
#   oidc_client_secret  the confidential client's secret
#   ...                 one property per var.app_secret_env entry
#
# The database role password comes from the Vault database engine
# (static-creds/<vault_role>, the vault stack's pg_app_roles map). The approver
# and reader tokens are minted by Terraform in authentik.tf.

resource "kubernetes_manifest" "app_secrets" {
  count = length(var.app_secret_env) > 0 ? 1 : 0

  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = local.app_secrets_name
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = local.app_secrets_name
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
        }
      }
      data = [
        for env_name in sort(keys(var.app_secret_env)) : {
          secretKey = env_name
          remoteRef = { key = local.vault_kv_name, property = var.app_secret_env[env_name] }
        }
      ]
    }
  }
  depends_on = [kubernetes_namespace.this]
}

resource "kubernetes_manifest" "auth_secrets" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = local.auth_secrets_name
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = local.auth_secrets_name
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
        }
      }
      data = [
        { secretKey = "BETTER_AUTH_SECRET", remoteRef = { key = local.vault_kv_name, property = "better_auth_secret" } },
        { secretKey = "OIDC_CLIENT_ID", remoteRef = { key = local.vault_kv_name, property = "oidc_client_id" } },
        { secretKey = "OIDC_CLIENT_SECRET", remoteRef = { key = local.vault_kv_name, property = "oidc_client_secret" } },
      ]
    }
  }
  depends_on = [kubernetes_namespace.this]
}

# DB credentials from the Vault database engine. The app reads DB_PASSWORD
# from a mounted file on every new connection, so a rotation needs no restart
# (the Deployment's reloader annotation leaves this Secret out).
resource "kubernetes_manifest" "db_creds" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = local.db_secret_name
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = local.db_secret_name
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
          data = {
            DB_PASSWORD = "{{ .password }}"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/${local.vault_role}"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.this]
}

# Request mode: AUTHENTIK_APPROVER_TOKEN and AUTHENTIK_USERS_GROUP_ID for the
# in-app approval (POST /api/v3/core/groups/<id>/add_user/).
resource "kubernetes_secret" "authentik_approver" {
  count = local.request_mode ? 1 : 0

  metadata {
    name      = "${var.name}-authentik-approver"
    namespace = kubernetes_namespace.this.metadata[0].name
  }
  data = {
    AUTHENTIK_APPROVER_TOKEN = module.signup.approver_token
    AUTHENTIK_USERS_GROUP_ID = module.signup.group_id
  }
}

resource "kubernetes_secret" "authentik_reader" {
  metadata {
    name      = "${var.name}-authentik-reader"
    namespace = kubernetes_namespace.this.metadata[0].name
  }
  data = {
    AUTHENTIK_READER_TOKEN = authentik_token.membership_reader.key
  }
}
