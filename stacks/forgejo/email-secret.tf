# SMTP password for Forgejo's open-signup email-confirmation + notification
# mail (main.tf: FORGEJO__service__REGISTER_EMAIL_CONFIRM + [mailer]). Synced
# from Vault secret/authentik -> smtp_password into the forgejo namespace as the
# `forgejo-email` Secret (key PASSWD), referenced by FORGEJO__mailer__PASSWD.
# Reuses the same noreply@viktorbarzin.me mailserver SASL account Authentik uses
# (stacks/authentik/email-secret.tf) — one credential, one rotation point. The
# reloader annotation rolls the Forgejo pod if the password is ever rotated.
resource "kubernetes_manifest" "forgejo_email_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "forgejo-email"
      namespace = "forgejo"
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "forgejo-email"
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
          secretKey = "PASSWD"
          remoteRef = { key = "authentik", property = "smtp_password" }
        },
      ]
    }
  }
}
