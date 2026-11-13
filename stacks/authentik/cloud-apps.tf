# The shared sign-in client for Cloud's private Apps (M2 contract, Addendum v2
# point 7, Viktor's session 2026-11-13; Cloud v1 plan in the cloud repo, "How
# does a private App check sign-in?").
#
# One OAuth2 provider and application, `cloud-apps`, owned by this repo and
# used by every private App's oauth2-proxy. Cloud's reconciler creates no
# Authentik object and holds no Authentik credential. It was first given an
# RBAC role to create one provider and application per App, but Authentik
# RBAC cannot limit group names, binding targets or group parents, and with
# core_default_app_access off (system-settings.tf) an unbound application
# admits nobody. So the binding lives here, once.
#
# Who gets through Authentik: active, signed-in people whose email something
# has vouched for (policy below). Each App's oauth2-proxy then admits only the
# email allowlist Cloud renders (the owner plus the App's `allow`), so the
# allowlist trusts the email in Authentik's token. Two things keep that email
# true:
#   - users cannot change their own email (default_user_change_email = false
#     in system-settings.tf);
#   - the policy admits only accounts whose email was vouched for when the
#     account was made. The invitation-enrollment flow (proxy-enrollment.tf)
#     asks for an email and never checks it, and Authentik does not require
#     emails to be unique, so an invitee could otherwise enroll as
#     victim@example.com and pass every allowlist naming that address.
#
# Redirect URIs: regex mode, one label under viktorbarzin.me, path
# /oauth2/callback only. Authentik matches regex redirect URIs with
# re.fullmatch, and the pattern is anchored too. A Cloud App name matches
# ^[a-z][a-z0-9-]{0,29}[a-z0-9]$, so every App host fits. The pattern also
# matches homelab hosts, so a holder of the client secret can redeem a code
# only if they also control a host that serves /oauth2/callback; Cloud's
# admission policies (stacks/cloud) keep Project Ingresses off homelab hosts.
#
# The client secret is copied into each Project namespace that has a private
# App (Cloud's secret/cloud/<namespace>/_cloud/<app>-oauth2-proxy, read only by
# External Secrets and the reconciler; App pods have no API token). With it
# and a matching host, someone can redeem codes for that host and read the
# signed-in user's profile and email. It signs nobody in to another App: each
# oauth2-proxy has its own cookie secret, host-bound cookie and allowlist.
# Rotate by tainting random_password.cloud_apps_client_secret; the apply
# rewrites secret/cloud/system and the reconciler copies the new secret on its
# next run of each Project.
#
# The client id is fixed: Cloud's admission policy cloud-managed-pod pins
# oauth2-proxy's `--client-id=cloud-apps` (stacks/cloud access_rules.tf,
# local.cloud_apps_client_id). Change both together.

locals {
  cloud_apps_slug      = "cloud-apps"
  cloud_apps_client_id = "cloud-apps"
  # One DNS label under the base domain, then /oauth2/callback; the same
  # label rule as a Cloud App name.
  cloud_apps_redirect_re = "^https://[a-z][a-z0-9-]{0,29}[a-z0-9]\\.viktorbarzin\\.me/oauth2/callback$"
  # The Authentik user path of accounts whose email a verification link
  # proved (signup-passkey.tf); cloud-apps-active-users admits them.
  cloud_apps_verified_path = "users/email-verified"
}

# Without a signing key Authentik signs HS256 and publishes an empty JWKS;
# oauth2-proxy verifies the ID token against /application/o/cloud-apps/jwks/.
data "authentik_certificate_key_pair" "cloud_apps_signing" {
  name = "authentik Self-signed Certificate"
}

data "authentik_property_mapping_provider_scope" "cloud_apps_openid" {
  managed = "goauthentik.io/providers/oauth2/scope-openid"
}

data "authentik_property_mapping_provider_scope" "cloud_apps_profile" {
  managed = "goauthentik.io/providers/oauth2/scope-profile"
}

data "authentik_property_mapping_provider_scope" "cloud_apps_email" {
  managed = "goauthentik.io/providers/oauth2/scope-email"
}

resource "random_password" "cloud_apps_client_secret" {
  length  = 64
  special = false
}

resource "authentik_provider_oauth2" "cloud_apps" {
  name          = local.cloud_apps_slug
  client_id     = local.cloud_apps_client_id
  client_type   = "confidential"
  client_secret = random_password.cloud_apps_client_secret.result

  authorization_flow = data.authentik_flow.default_authorization_implicit_consent.id
  invalidation_flow  = data.authentik_flow.default_provider_invalidation.id

  # redirect_uri_type is set on every entry: provider 2026.x reads it back,
  # and "authorization" is the server default.
  allowed_redirect_uris = [
    {
      matching_mode     = "regex"
      url               = local.cloud_apps_redirect_re
      redirect_uri_type = "authorization"
    },
  ]

  # The issuer is <authentik>/application/o/cloud-apps/. Cloud's oauth2-proxy
  # redeems codes at the in-cluster URL, and Authentik builds `iss` from the
  # request that redeemed the code, so the issuer it checks is the in-cluster
  # one.
  issuer_mode = "per_provider"
  signing_key = data.authentik_certificate_key_pair.cloud_apps_signing.id
  sub_mode    = "hashed_user_id"

  # oauth2-proxy reads the email from the ID token; its session cookie lasts
  # an hour and it asks for no refresh token.
  access_token_validity      = "minutes=10"
  include_claims_in_id_token = true

  property_mappings = [
    data.authentik_property_mapping_provider_scope.cloud_apps_openid.id,
    data.authentik_property_mapping_provider_scope.cloud_apps_profile.id,
    data.authentik_property_mapping_provider_scope.cloud_apps_email.id,
  ]

  # Authentik 2026.x creates a provider with an empty list, which refuses every
  # authorize request. oauth2-proxy sends PKCE S256 with the code grant.
  grant_types = ["authorization_code"]
}

resource "authentik_application" "cloud_apps" {
  name               = "Cloud Apps"
  slug               = local.cloud_apps_slug
  protocol_provider  = authentik_provider_oauth2.cloud_apps.id
  policy_engine_mode = "all"
  meta_description   = "Sign-in for Cloud's private Apps. Each App admits only its own email allowlist."
}

# Admits an active, signed-in account only when its email is vouched for:
#   - goauthentik.io/user/sources is set: Authentik's user write stage records
#     the social source (Google, GitHub, Facebook) that enrolled the account,
#     and the email came from that provider. Linking a source to an existing
#     account later writes no such record (core/sources/flow_manager.py, LINK).
#   - path users/email-verified: the passkey signup's write stage
#     (signup-passkey.tf) puts its accounts there; they stay inactive until the
#     emailed link is followed.
#   - attributes.cloud_apps_email_vouched is true: an admin sets it on an
#     account whose email they know, for example one made before Authentik
#     recorded sources. Users cannot write top-level attributes (the user
#     settings flow writes only attributes.settings).
# It refuses service accounts (API tokens, not people), `guest`, whom the
# public tier signs in automatically (guest.tf), and accounts carrying
# attributes.proxy_only: the proxy invitation on invitation-enrollment stamps
# it, also onto a signed-in account that reruns that flow and rewrites its
# own email there. Any other invitation on invitation-enrollment must carry
# attributes.proxy_only too (proxy-enrollment.tf). An anonymous request has
# is_authenticated False.
resource "authentik_policy_expression" "cloud_apps_active_users" {
  name       = "cloud-apps-active-users"
  expression = <<-EOT
    user = request.user
    if not user.is_authenticated or not user.is_active:
        return False
    if user.username == "guest":
        return False
    if str(user.type) in ("service_account", "internal_service_account"):
        return False
    attrs = user.attributes or {}
    if attrs.get("proxy_only"):
        return False
    if attrs.get("goauthentik.io/user/sources"):
        return True
    if user.path == "${local.cloud_apps_verified_path}":
        return True
    return attrs.get("cloud_apps_email_vouched") is True
  EOT
}

resource "authentik_policy_binding" "cloud_apps_active_users" {
  target = authentik_application.cloud_apps.uuid
  policy = authentik_policy_expression.cloud_apps_active_users.id
  order  = 0
}

# The reconciler reads secret/cloud/system (read-only for it, stacks/vault
# cloud_policies.tf). Terraform is the only writer of this secret:
#   cloud_apps_client_id      the client id above.
#   cloud_apps_client_secret  the client secret above.
#   ghcr_pull_token           a read:packages-only GitHub token for pulling
#                             Project images. It does not exist yet and must
#                             never be the admin PAT. Viktor mints it in the
#                             GitHub UI and stores it as
#                             `vault kv patch secret/viktor cloud_ghcr_pull_token=<token>`;
#                             the next apply of this stack copies it here.
#                             Empty until then, and the reconciler treats
#                             empty as "not set".
# CI writes this path through its own policy grant (stacks/vault, policy ci),
# so stacks/vault must be applied before this file's first CI apply.
data "vault_kv_secret_v2" "viktor_cloud" {
  mount = "secret"
  name  = "viktor"
}

resource "vault_kv_secret_v2" "cloud_system" {
  mount = "secret"
  name  = "cloud/system"
  data_json = jsonencode({
    cloud_apps_client_id     = authentik_provider_oauth2.cloud_apps.client_id
    cloud_apps_client_secret = random_password.cloud_apps_client_secret.result
    ghcr_pull_token          = lookup(data.vault_kv_secret_v2.viktor_cloud.data, "cloud_ghcr_pull_token", "")
  })
}
