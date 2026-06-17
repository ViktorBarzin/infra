# SMTP password for Authentik's signup-verification + recovery email (tripit
# ADR-0020). Synced from Vault secret/authentik.smtp_password into the authentik
# namespace as the `authentik-email` Secret, referenced by
# AUTHENTIK_EMAIL__PASSWORD in values.yaml (server.env + worker.env). The sender
# account is noreply@viktorbarzin.me (a mailserver SASL account); host/port/from
# are non-secret and live in values.yaml. The reloader annotation rolls the
# authentik pods if the password ever changes.
resource "kubernetes_manifest" "authentik_email_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "authentik-email"
      namespace = "authentik"
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "authentik-email"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
        }
      }
      data = [
        {
          secretKey = "AUTHENTIK_EMAIL__PASSWORD"
          remoteRef = { key = "authentik", property = "smtp_password" }
        },
      ]
    }
  }
}
