variable "postgresql_host" { type = string }

locals {
  namespace = "portal-assistant"
}

# Namespace for the Portal voice gateway (portal-assistant#1 PRD). This stack
# currently provisions only the CNPG database wiring (portal-assistant#4); the
# gateway Deployment/Service + Cloudflare ingress + device-token secret land in
# portal-assistant#10 and will extend this same stack.
resource "kubernetes_namespace" "portal_assistant" {
  metadata {
    name = local.namespace
    labels = {
      tier              = local.tiers.aux
      "istio-injection" = "disabled"
      # Opt into Keel auto-update (inject-keel-annotations ClusterPolicy) so the
      # gateway image added in #10 is picked up without extra wiring.
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label.
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# DB credentials from the Vault database engine (7-day rotation).
# Builds the asyncpg DSN consumed by the FastAPI gateway as DB_CONNECTION_STRING.
# Pre-reqs (both land before this applies cleanly):
#   - dbaas: CNPG cluster has DB `portal_assistant`, role `portal_assistant`,
#     schema `portal_assistant` (null_resource.pg_portal_assistant_db).
#   - vault: Vault role `static-creds/pg-portal-assistant`
#     (vault_database_secret_backend_static_role.pg_portal_assistant) + the role
#     added to the postgresql connection's allowed_roles.
# The synced K8s secret `portal-assistant-db-creds` exposes:
#   DB_CONNECTION_STRING — postgresql+asyncpg://portal_assistant:<pw>@<host>:5432/portal_assistant
#   DB_PASSWORD          — the rotating role password on its own (for non-DSN consumers)
# Reloader restarts consumers (the gateway, once #10 adds it) whenever ESO
# refreshes this secret on each 7-day rotation.
resource "kubernetes_manifest" "db_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "portal-assistant-db-creds"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "portal-assistant-db-creds"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
          data = {
            DB_CONNECTION_STRING = "postgresql+asyncpg://portal_assistant:{{ .password }}@${var.postgresql_host}:5432/portal_assistant"
            DB_PASSWORD          = "{{ .password }}"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/pg-portal-assistant"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.portal_assistant]
}
