# Signed-in Members of tv.viktorbarzin.me, formerly f1.viktorbarzin.me
# (f1-stream ADR-0025, ADR-0021, ADR-0042, ADR-0053).
#
# Anyone in "Home Users" or "F1 Users" may sign in to the site, keep their own
# channel order (My channels) and pair a TV that shows it. Home Server Admins
# pass as well. Home Users is the household (stacks/authentik/home-users.tf,
# infra ADR-0031). F1 Users is for other households, who ask from an unpaired
# TV and are let in by an admin in the app (ADR-0042, "Access requests"
# below), whether they sign up there or already had an Authentik account;
# Terraform declares that group but not its members. The app reads
# both names from MEMBER_GROUPS (main.tf).
# Design: f1-stream docs/design/2026-10-10-my-channels.md; wire format:
# docs/design/2026-10-10-my-channels-build-contract.md.
#
# WHY OIDC AND NOT A FORWARD-AUTH PATH. The /admin/login and /pair carve-outs in
# main.tf and tv-pairing.tf sit behind the domain-wide forward-auth
# application, which admits Home Server Admins only (infra ADR-0031 has the
# reasoning). A member of any other group is refused there before the request
# reaches the app. A per-host forward_single application cannot help here
# either, because its login callback would land on the public "/" route. An
# OAuth2 application of its own is how TripIt solved the same problem for its
# website (stacks/tripit/authentik.tf): Authentik enforces the group bindings
# below at the authorize step, the app checks the groups claim again and mints
# its own session cookie.
#
# Membership is declared in stacks/authentik/home-users.tf, which also owns the
# group; this stack only reads it. stacks/authentik is a platform stack and
# applies before this one in the same pipeline, so the group exists by the
# time this plan reads it.
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

data "authentik_group" "home_users" {
  name          = "Home Users"
  include_users = false
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

  # The app builds redirect_uri from the host the browser used, so each app
  # host needs its own callback. tv is the product's home since 2026-10-29
  # (f1-stream ADR-0053); f1's entry goes once f1 only redirects to tv.
  allowed_redirect_uris = [
    {
      matching_mode     = "strict"
      url               = "https://tv.viktorbarzin.me/auth/callback"
      redirect_uri_type = "authorization"
    },
    {
      matching_mode     = "strict"
      url               = "https://f1.viktorbarzin.me/auth/callback"
      redirect_uri_type = "authorization"
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

  # Authentik 2026.x keeps a per-provider list of allowed grant types and
  # creates a new provider with that list empty, which refuses every authorize
  # request ("Invalid grant_type for provider: authorization_code", measured
  # 2026-10-10). Until the 2026.x provider landed this was set through the API
  # by a terraform_data local-exec; the provider now manages it directly.
  grant_types = ["authorization_code"]
}

resource "authentik_application" "f1_stream" {
  # Shown on the Authentik sign-in page and in the user's app list. The slug
  # stays: app-access-guard.tf and the access-request policy key on it.
  name               = "TV"
  slug               = "f1-stream"
  protocol_provider  = authentik_provider_oauth2.f1_stream.id
  meta_launch_url    = "https://tv.viktorbarzin.me"
  policy_engine_mode = "any"
}

# Default-deny: without a binding Authentik lets any authenticated user
# through an OAuth2 application, which is what app-access-bindings.tf closed
# for the other OIDC apps on 2026-07-26.
#
# A new resource address rather than an edit of `f1_stream_members`: on
# 2026-10-11 the authentik stack deleted the F1 Users group before this stack
# repointed the binding, the deletion cascaded to the binding, and state was
# left pointing at an object that no longer exists. The removed block forgets
# that entry without trying to delete it again.
removed {
  from = authentik_policy_binding.f1_stream_members
  lifecycle {
    destroy = false
  }
}

resource "authentik_policy_binding" "f1_stream_home_users" {
  target = authentik_application.f1_stream.uuid
  group  = data.authentik_group.home_users.id
  order  = 0
}

resource "authentik_policy_binding" "f1_stream_admins" {
  target = authentik_application.f1_stream.uuid
  group  = data.authentik_group.home_server_admins.id
  order  = 1
}

resource "authentik_policy_binding" "f1_stream_f1_users" {
  target = authentik_application.f1_stream.uuid
  group  = module.f1_users.group_id
  order  = 2
}

# A person who already has an Authentik account outside these groups and
# scans an unpaired TV's QR (f1-stream ADR-0042, decided 2026-10-18). The
# policy lets that account through the authorize step only for a join state
# (`j.<ref>.<random>`, which /join/<ref> sends), after recording an Access
# request on it (modules/authentik/app_signup). The app sees no member group
# in the ID token and sends the person to /join/pending, signed in to
# nothing, until an admin approves. Without this, Authentik showed such a
# person its access-denied page. app-access-guard.tf accepts this binding by
# the policy's name.
resource "authentik_policy_binding" "f1_stream_access_request" {
  target = authentik_application.f1_stream.uuid
  policy = module.f1_users.existing_account_policy_id
  order  = 3
}

# --- Access requests: F1 Users through request-mode sign-up -------------------
#
# f1-stream ADR-0042. An unpaired TV shows a QR that starts this application's
# authorize request. A new person signs up with Google on that path without an
# invite code (stacks/authentik/app-signup.tf), gets an account with no group,
# and lands on pending_url. Someone who already has an account takes the
# f1_stream_access_request binding above instead and reaches the same page
# through the app's callback. A Home Server Admin approves in the app, on an
# Admin TV or on /account, and the app adds the person to F1 Users with the
# approver token below, which can add users to that one group and nothing
# else. Every other sign-up path still asks for an invite code.

module "f1_users" {
  source = "../../modules/authentik/app_signup"

  app_slug    = authentik_application.f1_stream.slug
  group_name  = "F1 Users"
  mode        = "request"
  pending_url = "https://tv.viktorbarzin.me/join/pending"

  # /join/<ref> starts the authorize request with state j.<ref>.<random>.
  existing_account_state_prefix = "j."
}

# --- Membership check: a read-only service account ---------------------------
#
# The app asks Authentik whether a Member is still in Home Users when the site
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
    purpose    = "f1-stream reads whether a Member is still in Home Users"
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
    oidc_client_secret       = random_password.oidc_client_secret.result
    authentik_api_token      = authentik_token.f1_membership.key
    authentik_approver_token = module.f1_users.approver_token
  }
}
