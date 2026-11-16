# The shared sign-in client for Cloud's Apps, every App, public or private
# (M2 contract, Addendum v2 point 7, Viktor's session 2026-11-13; Cloud v1
# plan in the cloud repo, "How does a private App check sign-in?"; app-kit
# K1, 2026-11-14).
#
# One OAuth2 provider and application, `cloud-apps`, owned by this repo and
# used by the oauth2-proxy of every App, public or private. Cloud's
# reconciler creates no Authentik object and holds no Authentik credential.
# It was first given an RBAC role to create one provider and application per
# App, but Authentik RBAC cannot limit group names, binding targets or group
# parents, and with core_default_app_access off (system-settings.tf) an
# unbound application admits nobody. So the binding lives here, once.
#
# Who gets through Authentik: active, signed-in people whose email something
# has vouched for (policy below). A private App's oauth2-proxy then admits
# only the email allowlist Cloud renders (the owner plus the App's `allow`),
# so the allowlist trusts the email in Authentik's token. A public App's
# oauth2-proxy admits any account cloud-apps admits. Two things keep that
# email true:
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
# The client secret is copied for every App, public or private, into its
# Project namespace (Cloud's secret/cloud/<namespace>/_cloud/<app>-oauth2-proxy,
# read only by External Secrets and the reconciler; App pods have no API
# token). With it and a matching host, someone can redeem codes for that host
# and read the signed-in user's profile and email. It signs nobody in to
# another App: each oauth2-proxy has its own cookie secret and host-bound
# cookie, and a private App's has its own allowlist.
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
  # Direct members are accounts an Operator vouched for (below).
  cloud_apps_vouched_group = "Cloud Email Vouched"
}

# An Operator's email vouch, as group membership instead of a user
# attribute: Cloud's onboarding (cloud-inviter.tf) adds an account here when
# the Operator says its email belongs to that person, which needs only an
# object permission on this group, never change_user. Only direct membership
# counts (user.groups, not all_groups()), so a child group vouches for
# nobody. No application binds it and it grants nothing else. Members are
# added at run time; Terraform does not own them.
resource "authentik_group" "cloud_email_vouched" {
  name         = local.cloud_apps_vouched_group
  is_superuser = false
  attributes = jsonencode({
    managed_by = "infra/stacks/authentik/cloud-apps.tf"
    purpose    = "Accounts whose email an Operator vouched for (cloud users add). cloud-apps-active-users and Cloud's email claim trust their email. Grants nothing else."
  })
  lifecycle {
    ignore_changes = [users]
  }
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

  # Explicit consent: a visitor sees a screen before Authentik issues a code,
  # so a hostile public App cannot silently collect one in a frame or popup.
  # It narrows, but does not close, code capture through the shared client
  # (cloud repo docs/build/final-infra.md, "The code capture stays open").
  authorization_flow = data.authentik_flow.default_authorization_explicit_consent.id
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
  meta_description   = "Sign-in for every Cloud App, public or private. A private App admits only its own email allowlist; a public App admits any account allowed here."
}

# Admits an active, signed-in account only when its email is vouched for:
#   - goauthentik.io/user/sources is set: Authentik's user write stage records
#     the social source (Google, GitHub, Facebook) that enrolled the account,
#     and the email came from that provider. Linking a source to an existing
#     account later writes no such record (core/sources/flow_manager.py, LINK).
#   - path users/email-verified: the passkey signup's write stage
#     (signup-passkey.tf) puts its accounts there; they stay inactive until the
#     emailed link is followed.
#   - direct membership of Cloud Email Vouched: an Operator vouched for the
#     email through Cloud's onboarding (`cloud users add`).
#   - attributes.cloud_apps_email_vouched is true: an admin sets it on an
#     account whose email they know, for example one made before Authentik
#     recorded sources. Users cannot write top-level attributes (the user
#     settings flow writes only attributes.settings). Kept for accounts
#     vouched before the group existed.
# It refuses service accounts (API tokens, not people), `guest`, whom the
# public tier signs in automatically (guest.tf), and accounts carrying
# attributes.proxy_only: the proxy invitation on invitation-enrollment stamps
# it, also onto a signed-in account that reruns that flow and rewrites its
# own email there. Any other invitation on invitation-enrollment must carry
# attributes.proxy_only too (proxy-enrollment.tf). An anonymous request has
# is_authenticated False. Cloud's guest invites apply the same test to say
# who needs no code (src/server/homelab-accounts.server.ts, admitted());
# change both together.
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
    if user.groups.filter(name="${local.cloud_apps_vouched_group}").exists():
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
# cloud_policies.tf). Terraform writes these keys, and carries over the
# hand-written ones listed below:
#   cloud_apps_client_id      the client id above.
#   cloud_apps_client_secret  the client secret above.
#   ghcr_pull_token           the GitHub token for pulling Project images,
#                             copied from `secret/viktor`
#                             `cloud_ghcr_pull_token`. Since 2026-11-14 that
#                             key holds Viktor's classic `github_pat`, his
#                             choice (docs/runbooks/cloud.md, "Turning builds
#                             on"), so the reconciler copies the full PAT
#                             into every Project namespace's pull secret.
#                             To narrow it (cloud backlog B08b), Viktor mints
#                             a read:packages-only token in the GitHub UI,
#                             runs `vault kv patch secret/viktor cloud_ghcr_pull_token=<token>`,
#                             and the next apply of this stack copies it
#                             here. The reconciler treats empty as "not set".
# CI writes this path through its own policy grant (stacks/vault, policy ci),
# so stacks/vault must be applied before this file's first CI apply.
#
# Keys Terraform carries over: Cloud's M5 keys (cloud repo,
# docs/build/m5-infra.md), which Viktor writes by hand with `vault kv patch`
# because Terraform cannot make them (an X25519 key pair, GitHub and Forgejo
# tokens). A write of data_json replaces the whole secret (the vault
# provider PUTs data_json alone), so without this the next change to the
# three keys above would delete them, and losing secrets_private_key makes
# every App secret Cloud has sealed unreadable. Each key is read back from
# the live secret and written again unchanged; a key not set yet stays absent.
#   secrets_private_key, secrets_public_key  the App secrets key pair
#   github_dispatch_token, github_owner_read_token, forgejo_read_token,
#   forgejo_admin_token                      the reconciler's build tokens;
#                                            both GitHub ones hold
#                                            github_pat too (runbook)
#   github_api_token                         the console's private-repo check
#   ghcr_delete_token                        deletes a gone App's ghcr images
#                                            (Viktor's github_pat, which has
#                                            delete:packages; his call 2026-11-14)
#   build_log_key                            opens the build logs the public
#                                            builder seals (cloud B05)
locals {
  cloud_system_carried_keys = [
    "secrets_private_key",
    "secrets_public_key",
    "github_dispatch_token",
    "github_owner_read_token",
    "forgejo_read_token",
    "forgejo_admin_token",
    "github_api_token",
    "ghcr_delete_token",
    # Builder v2 (cloud B05): Cloud's age identity for the sealed build logs.
    "build_log_key",
  ]
  cloud_system_live = length(data.vault_kv_secret_v2.cloud_system_live) > 0 ? data.vault_kv_secret_v2.cloud_system_live[0].data : {}
}

# Lists secret/cloud/ so a first apply, before cloud/system exists, reads
# nothing instead of failing. The provider marks the names sensitive; whether
# one is "system" is not.
data "vault_kv_secrets_list_v2" "cloud" {
  mount = "secret"
  name  = "cloud"
}

data "vault_kv_secret_v2" "cloud_system_live" {
  count = nonsensitive(contains(data.vault_kv_secrets_list_v2.cloud.names, "system")) ? 1 : 0
  mount = "secret"
  name  = "cloud/system"
}

data "vault_kv_secret_v2" "viktor_cloud" {
  mount = "secret"
  name  = "viktor"
}

resource "vault_kv_secret_v2" "cloud_system" {
  mount = "secret"
  name  = "cloud/system"
  data_json = jsonencode(merge(
    { for k in local.cloud_system_carried_keys : k => lookup(local.cloud_system_live, k, null) if lookup(local.cloud_system_live, k, null) != null },
    {
      cloud_apps_client_id     = authentik_provider_oauth2.cloud_apps.client_id
      cloud_apps_client_secret = random_password.cloud_apps_client_secret.result
      ghcr_pull_token          = lookup(data.vault_kv_secret_v2.viktor_cloud.data, "cloud_ghcr_pull_token", "")
    },
  ))
}
