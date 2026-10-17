# Identity (ADR-0001, "Identity and access"). The app signs people in with
# Better Auth's generic OAuth plugin against the OAuth2 application below.
#
# Who can sign in:
#   <App> Users         members. New people ask for access through the
#                       sign-up flow (module.signup): in request mode an admin
#                       approves them inside the app.
#   <App> Admins        approve requests inside the app.
#   <App> Agents        optional, for non-human clients (var.agents_group).
#   Home Server Admins  as for every other app here (bind_home_server_admins).

data "vault_kv_secret_v2" "app" {
  mount = "secret"
  name  = local.vault_kv_name
}

data "authentik_flow" "default_authorization_implicit_consent" {
  slug = "default-provider-authorization-implicit-consent"
}

# Without a signing key Authentik signs HS256 and publishes an empty JWKS.
data "authentik_certificate_key_pair" "signing" {
  name = "authentik Self-signed Certificate"
}

data "authentik_property_mapping_provider_scope" "openid" {
  managed = "goauthentik.io/providers/oauth2/scope-openid"
}

# Carries `groups` and `preferred_username`.
data "authentik_property_mapping_provider_scope" "profile" {
  managed = "goauthentik.io/providers/oauth2/scope-profile"
}

data "authentik_property_mapping_provider_scope" "email" {
  managed = "goauthentik.io/providers/oauth2/scope-email"
}

data "authentik_group" "home_server_admins" {
  count         = var.bind_home_server_admins ? 1 : 0
  name          = "Home Server Admins"
  include_users = false
}

resource "authentik_provider_oauth2" "this" {
  name          = var.name
  client_id     = var.name # mirrored in secret/<vault_kv_name> oidc_client_id for the ExternalSecret
  client_type   = "confidential"
  client_secret = data.vault_kv_secret_v2.app.data["oidc_client_secret"]

  authorization_flow = data.authentik_flow.default_authorization_implicit_consent.id
  invalidation_flow  = var.invalidation_flow

  # redirect_uri_type is set on every entry: provider 2026.x reads it back,
  # and "authorization" is the server default.
  allowed_redirect_uris = [
    for origin in local.public_origins : {
      matching_mode     = "strict"
      url               = "${origin}${var.oidc_callback_path}"
      redirect_uri_type = "authorization"
    }
  ]

  # The app keys users on `sub` and never on email. The issuer is
  # <authentik_url>/application/o/<name>/, which the app's token verifier pins
  # along with RS256 and aud = client_id.
  sub_mode    = "hashed_user_id"
  issuer_mode = "per_provider"
  signing_key = data.authentik_certificate_key_pair.signing.id

  access_token_validity      = var.access_token_validity
  include_claims_in_id_token = true

  # Web sign-in does not request offline_access, so no offline_access mapping
  # and no refresh_token grant.
  property_mappings = [
    data.authentik_property_mapping_provider_scope.openid.id,
    data.authentik_property_mapping_provider_scope.profile.id,
    data.authentik_property_mapping_provider_scope.email.id,
  ]

  # Authentik 2026.x creates a provider with an empty list, which refuses every
  # authorize request.
  grant_types = var.grant_types
}

resource "authentik_application" "this" {
  name               = var.display_name
  slug               = var.name
  protocol_provider  = authentik_provider_oauth2.this.id
  meta_launch_url    = "https://${local.host}"
  policy_engine_mode = "any"
}

# "<App> Users" and the sign-up registration. app_slug must match the
# application slug: the shared sign-up flow (stacks/authentik/app-signup.tf)
# finds the group through it. In request mode a requester lands on
# pending_url, which the app serves.
module "signup" {
  source = "../../authentik/app_signup"

  app_slug      = authentik_application.this.slug
  group_name    = local.users_group
  mode          = var.signup_mode
  pending_url   = "https://${local.host}${var.pending_path}"
  initial_users = var.initial_user_pks
}

# Approves requests inside the app. Membership is declared here and is
# authoritative.
resource "authentik_group" "admins" {
  name  = local.admins_group
  users = var.admin_user_pks
}

resource "authentik_group" "agents" {
  count = var.agents_group != null ? 1 : 0
  name  = var.agents_group
}

# Every binding is a group membership check, which app-access-guard.tf in the
# authentik stack requires under policy_engine_mode "any".
resource "authentik_policy_binding" "users" {
  target = authentik_application.this.uuid
  group  = module.signup.group_id
  order  = 0
}

resource "authentik_policy_binding" "admins" {
  target = authentik_application.this.uuid
  group  = authentik_group.admins.id
  order  = 1
}

resource "authentik_policy_binding" "home_server_admins" {
  count  = var.bind_home_server_admins ? 1 : 0
  target = authentik_application.this.uuid
  group  = data.authentik_group.home_server_admins[0].id
  order  = 2
}

resource "authentik_policy_binding" "agents" {
  count  = var.agents_group != null ? 1 : 0
  target = authentik_application.this.uuid
  group  = authentik_group.agents[0].id
  order  = 3
}

# Membership re-checks (every 15 minutes per signed-in user) read the user and
# their groups with this token: GET /api/v3/core/users/?username=..&include_groups=true.
# Without it every re-check fails closed. view_user has to be global because
# any Authentik user may try to sign in; view_group is held only on the users
# group, the one group the app looks up by name. Same shape as
# stacks/f1-stream/members.tf.
resource "authentik_rbac_role" "membership_reader" {
  name = "${var.name} membership reader"
}

resource "authentik_rbac_permission_role" "reader_view_user" {
  role       = authentik_rbac_role.membership_reader.id
  permission = "authentik_core.view_user"
}

resource "authentik_rbac_permission_role" "reader_view_users_group" {
  role       = authentik_rbac_role.membership_reader.id
  permission = "authentik_core.view_group"
  model      = "authentik_core.group"
  object_id  = module.signup.group_id
}

resource "authentik_group" "membership_readers" {
  name  = "${var.name} membership readers"
  roles = [authentik_rbac_role.membership_reader.id]
  # Holds only the service account below, which the user resource adds.
  lifecycle {
    ignore_changes = [users]
  }
}

resource "authentik_user" "membership_reader" {
  username = "svc-${var.name}-reader"
  name     = "${var.name} (membership check)"
  type     = "service_account"
  path     = "goauthentik.io/service-accounts"
  groups   = [authentik_group.membership_readers.id]

  attributes = jsonencode({
    managed_by = var.reader_managed_by
    purpose    = "${var.name} re-checks that a signed-in user is still in ${local.users_group} or ${local.admins_group}"
  })
}

resource "authentik_token" "membership_reader" {
  identifier   = "svc-${var.name}-reader"
  user         = authentik_user.membership_reader.id
  intent       = "api"
  retrieve_key = true
  # Non-expiring, like the approver token: a token that lapses on a date
  # nobody watches turns every re-check into a sign-out. Rotate by tainting
  # this resource.
  expiring    = false
  description = "${var.name} membership re-check. Rotate by tainting this resource."
}
