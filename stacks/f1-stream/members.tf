# Signed-in Members of f1.viktorbarzin.me (f1-stream ADR-0025, ADR-0021).
#
# Anyone in "F1 Users" may sign in to the site, keep their own channel order
# (My channels) and pair a TV that shows it. Home Server Admins pass as well.
# Design: f1-stream docs/design/2026-10-10-my-channels.md; wire format:
# docs/design/2026-10-10-my-channels-build-contract.md.
#
# WHY OIDC AND NOT A FORWARD-AUTH PATH. The /admin/login and /pair carve-outs in
# main.tf and tv-pairing.tf sit behind the domain-wide forward-auth
# application, which since 2026-09-19 admits Home Server Admins only
# (stacks/authentik/admin-services-restriction.tf has the reasoning). A member
# of any other group is refused there before the request reaches the app. An
# OAuth2 application of its own is how TripIt solved the same problem for its
# website (stacks/tripit/authentik.tf): Authentik enforces the group bindings
# below at the authorize step, the app checks the groups claim again and mints
# its own session cookie.
#
# Membership is managed in Authentik, not here: `users` is left unset, so this
# stack owns the group's existence and nothing about who is in it. Add or
# remove people in the Authentik UI.
#
# Secrets never leave Terraform state. The OIDC client secret is generated
# here and the membership API token is minted here, and both go straight into a
# Secret in the f1-stream namespace, the way ingress-proof.tf handles its
# shared value. Nothing for Vault or an ExternalSecret to add.

data "vault_kv_secret_v2" "authentik_tf" {
  mount = "secret"
  name  = "authentik"
}

provider "authentik" {
  url   = "https://authentik.viktorbarzin.me"
  token = data.vault_kv_secret_v2.authentik_tf.data["tf_api_token"]
}

resource "authentik_group" "f1_users" {
  name = "F1 Users"
}

data "authentik_group" "home_server_admins" {
  name          = "Home Server Admins"
  include_users = false
}

# --- Sign-in: the f1-stream OAuth2 application --------------------------------

data "authentik_flow" "default_authorization_implicit_consent" {
  slug = "default-provider-authorization-implicit-consent"
}

data "authentik_certificate_key_pair" "signing" {
  name = "authentik Self-signed Certificate"
}

data "authentik_property_mapping_provider_scope" "openid" {
  managed = "goauthentik.io/providers/oauth2/scope-openid"
}

# The profile scope is what carries `groups` (names) and `preferred_username`,
# the two claims the app reads.
data "authentik_property_mapping_provider_scope" "profile" {
  managed = "goauthentik.io/providers/oauth2/scope-profile"
}

data "authentik_property_mapping_provider_scope" "email" {
  managed = "goauthentik.io/providers/oauth2/scope-email"
}

resource "random_password" "oidc_client_secret" {
  length  = 64
  special = false
}

resource "authentik_provider_oauth2" "f1_stream" {
  name          = "f1-stream"
  client_id     = "f1-stream"
  client_type   = "confidential"
  client_secret = random_password.oidc_client_secret.result

  authorization_flow = data.authentik_flow.default_authorization_implicit_consent.id
  # Pinned literal, as in stacks/tripit/authentik.tf: the flow data source for
  # the invalidation flow intermittently resolved null in CI under the
  # provider/server version skew. This is default-provider-invalidation-flow.
  invalidation_flow = "b0a43377-0fa6-45d1-89fc-ed298bb1bb53"

  allowed_redirect_uris = [
    {
      matching_mode = "strict"
      url           = "https://f1.viktorbarzin.me/auth/callback"
    },
  ]

  # The app reads the ID token once at sign-in and then lives on its own
  # cookie, so nothing here needs to outlast the redirect.
  access_token_validity      = "minutes=5"
  include_claims_in_id_token = true
  signing_key                = data.authentik_certificate_key_pair.signing.id

  property_mappings = [
    data.authentik_property_mapping_provider_scope.openid.id,
    data.authentik_property_mapping_provider_scope.profile.id,
    data.authentik_property_mapping_provider_scope.email.id,
  ]
}

resource "authentik_application" "f1_stream" {
  name               = "F1 Stream"
  slug               = "f1-stream"
  protocol_provider  = authentik_provider_oauth2.f1_stream.id
  meta_launch_url    = "https://f1.viktorbarzin.me"
  policy_engine_mode = "any"
}

# Default-deny: without a binding Authentik lets any authenticated user
# through an OAuth2 application, which is what app-access-bindings.tf closed
# for the other OIDC apps on 2026-07-26.
resource "authentik_policy_binding" "f1_stream_members" {
  target = authentik_application.f1_stream.uuid
  group  = authentik_group.f1_users.id
  order  = 0
}

resource "authentik_policy_binding" "f1_stream_admins" {
  target = authentik_application.f1_stream.uuid
  group  = data.authentik_group.home_server_admins.id
  order  = 1
}

# --- Membership check: a read-only service account ---------------------------
#
# The app asks Authentik whether a Member is still in F1 Users when the site
# loads and when a TV launches (ADR-0021), and unpairs the TVs of anyone who
# has left. Reading users and their groups is all it needs, granted through a
# role on a group of its own so the account holds nothing else.

resource "authentik_rbac_role" "f1_membership_reader" {
  name = "f1-stream membership reader"
}

resource "authentik_rbac_permission_role" "f1_view_user" {
  role       = authentik_rbac_role.f1_membership_reader.id
  permission = "authentik_core.view_user"
}

resource "authentik_rbac_permission_role" "f1_view_group" {
  role       = authentik_rbac_role.f1_membership_reader.id
  permission = "authentik_core.view_group"
}

resource "authentik_group" "f1_membership_readers" {
  name  = "f1-stream membership readers"
  roles = [authentik_rbac_role.f1_membership_reader.id]
}

resource "authentik_user" "f1_stream" {
  username = "svc-f1-stream"
  name     = "f1-stream (membership check)"
  type     = "service_account"
  path     = "goauthentik.io/service-accounts"
  groups   = [authentik_group.f1_membership_readers.id]

  attributes = jsonencode({
    managed_by = "infra/stacks/f1-stream/members.tf"
    purpose    = "f1-stream reads whether a Member is still in F1 Users"
  })
}

resource "authentik_token" "f1_membership" {
  identifier   = "svc-f1-stream-membership"
  user         = authentik_user.f1_stream.id
  intent       = "api"
  retrieve_key = true
  # Non-expiring, like svc-agent's: a token that lapses on a date nobody is
  # watching would quietly turn every check into "Authentik unreachable".
  # Rotate by tainting this resource.
  expiring    = false
  description = "f1-stream membership check. Rotate by tainting this resource."
}

resource "kubernetes_secret" "f1_members" {
  metadata {
    name      = "f1-stream-members"
    namespace = kubernetes_namespace.f1-stream.metadata[0].name
  }
  data = {
    oidc_client_secret  = random_password.oidc_client_secret.result
    authentik_api_token = authentik_token.f1_membership.key
  }
}
