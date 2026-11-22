# Authentik OIDC application for Bambuddy. Bambuddy reads its one OIDC
# provider from the BAMBUDDY_OIDC_* environment in main.tf and signs people in
# at /api/v1/auth/oidc/callback.
#
# Who can sign in: Home Server Admins (Viktor and Emo), through the policy
# binding below. Bambuddy creates the account on the first login and puts it
# in its Administrators group, from the `groups` claim of the profile scope.

data "vault_kv_secret_v2" "authentik_tf" {
  mount = "secret"
  name  = "authentik"
}

provider "authentik" {
  url   = "https://authentik.viktorbarzin.me"
  token = data.vault_kv_secret_v2.authentik_tf.data["tf_api_token"]
}

data "vault_kv_secret_v2" "bambuddy" {
  mount = "secret"
  name  = "bambuddy"
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

# Carries the `groups` claim that BAMBUDDY_OIDC_GROUP_MAPPING reads.
data "authentik_property_mapping_provider_scope" "profile" {
  managed = "goauthentik.io/providers/oauth2/scope-profile"
}

data "authentik_property_mapping_provider_scope" "email" {
  managed = "goauthentik.io/providers/oauth2/scope-email"
}

data "authentik_group" "home_server_admins" {
  name          = "Home Server Admins"
  include_users = false
}

resource "authentik_provider_oauth2" "bambuddy" {
  name          = "bambuddy"
  client_id     = local.oidc_client_id
  client_type   = "confidential"
  client_secret = data.vault_kv_secret_v2.bambuddy.data["oidc_client_secret"]

  authorization_flow = data.authentik_flow.default_authorization_implicit_consent.id
  # default-provider-invalidation-flow, pinned as in stacks/glitchtip (the flow
  # data source has resolved null in CI).
  invalidation_flow = "b0a43377-0fa6-45d1-89fc-ed298bb1bb53"

  allowed_redirect_uris = [
    {
      matching_mode     = "strict"
      url               = "https://${local.host}/api/v1/auth/oidc/callback"
      redirect_uri_type = "authorization"
    },
  ]

  issuer_mode = "per_provider"
  signing_key = data.authentik_certificate_key_pair.signing.id

  access_token_validity      = "hours=1"
  include_claims_in_id_token = true

  property_mappings = [
    data.authentik_property_mapping_provider_scope.openid.id,
    data.authentik_property_mapping_provider_scope.profile.id,
    data.authentik_property_mapping_provider_scope.email.id,
  ]

  # Authentik 2026.x creates a provider with an empty list, which refuses every
  # authorize request.
  grant_types = ["authorization_code"]
}

resource "authentik_application" "bambuddy" {
  name               = "Bambuddy"
  slug               = "bambuddy"
  protocol_provider  = authentik_provider_oauth2.bambuddy.id
  meta_launch_url    = "https://${local.host}"
  policy_engine_mode = "any"
}

# A group membership check, as app-access-guard.tf in the authentik stack
# requires under policy_engine_mode "any".
resource "authentik_policy_binding" "home_server_admins" {
  target = authentik_application.bambuddy.uuid
  group  = data.authentik_group.home_server_admins.id
  order  = 0
}
