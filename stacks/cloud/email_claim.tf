# Cloud's own `email` scope mapping (M5), used by the console's provider
# (module.console, console.tf) and cloud-cli (cli_sign_in.tf) in place of
# Authentik's managed scope-email, which always sends email_verified false
# (checked 2026-11-13, Authentik 2026.8.5).
#
# Why: the owner access check (cloud repo, docs/build/m5-infra.md) finds a
# Project owner's Forgejo account by an email both sides verified. Cloud reads
# email_verified from the owner's sign-in profile, so it must be true only for
# an email something has vouched for.
#
# The rule is the one stacks/authentik cloud-apps.tf applies to Cloud's
# private Apps (policy cloud-apps-active-users): an active person, not
# `guest`, not a service account, not a proxy-only invitee, and one of
#   - a social source enrolled the account (goauthentik.io/user/sources),
#   - the passkey signup verified the email (path users/email-verified),
#   - an admin set attributes.cloud_apps_email_vouched to true.
# Users cannot change their email or write those attributes (system-
# settings.tf and the user settings flow in stacks/authentik). The two copies
# must agree: tests/cloud-deploy.test.sh runs both on the same accounts.
#
# The email itself is sent for everyone, as before; only the claim differs.

locals {
  cloud_email_verified_path = "users/email-verified"

  cloud_email_claim_expression = <<-EOT
    user = request.user
    attrs = user.attributes or {}
    vouched = (
        user.is_active
        and user.username != "guest"
        and str(user.type) not in ("service_account", "internal_service_account")
        and not attrs.get("proxy_only")
        and (
            bool(attrs.get("goauthentik.io/user/sources"))
            or user.path == "${local.cloud_email_verified_path}"
            or attrs.get("cloud_apps_email_vouched") is True
        )
    )
    return {"email": user.email, "email_verified": vouched}
  EOT
}

resource "authentik_property_mapping_provider_scope" "cloud_email" {
  name        = "cloud: email (verified when vouched for)"
  scope_name  = "email"
  description = "Email address; email_verified only when vouched for"
  expression  = local.cloud_email_claim_expression
}
