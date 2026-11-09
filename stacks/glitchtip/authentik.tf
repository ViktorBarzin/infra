# Authentik OIDC application for GlitchTip (ADR-0041). GlitchTip signs people
# in through django-allauth's OpenID Connect provider; the matching allauth
# SocialApp is written by the `oidc-app` init container in main.tf from the
# same client id and secret.
#
# Who can sign in: Home Server Admins only, through the policy binding below.
# GlitchTip's own sign-up stays closed (ENABLE_USER_REGISTRATION = false), and
# an account is created on the first OIDC login of someone Authentik admits.

data "vault_kv_secret_v2" "authentik_tf" {
  mount = "secret"
  name  = "authentik"
}

provider "authentik" {
  url   = "https://authentik.viktorbarzin.me"
  token = data.vault_kv_secret_v2.authentik_tf.data["tf_api_token"]
}

data "vault_kv_secret_v2" "glitchtip" {
  mount = "secret"
  name  = "glitchtip"
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

data "authentik_property_mapping_provider_scope" "profile" {
  managed = "goauthentik.io/providers/oauth2/scope-profile"
}

# GlitchTip keys accounts on email (ACCOUNT_LOGIN_METHODS = {"email"}), so the
# email claim is required for the first login to create the account.
data "authentik_property_mapping_provider_scope" "email" {
  managed = "goauthentik.io/providers/oauth2/scope-email"
}

data "authentik_group" "home_server_admins" {
  name          = "Home Server Admins"
  include_users = false
}

resource "authentik_provider_oauth2" "glitchtip" {
  name          = "glitchtip"
  client_id     = local.oidc_client_id
  client_type   = "confidential"
  client_secret = data.vault_kv_secret_v2.glitchtip.data["oidc_client_secret"]

  authorization_flow = data.authentik_flow.default_authorization_implicit_consent.id
  # default-provider-invalidation-flow, pinned as in stacks/tripit and
  # modules/kubernetes/tanstack_app (the flow data source has resolved null in CI).
  invalidation_flow = "b0a43377-0fa6-45d1-89fc-ed298bb1bb53"

  # allauth's OpenID Connect callback: /accounts/<OPENID_CONNECT_URL_PREFIX,
  # default "oidc">/<provider_id>/login/callback/. provider_id is "authentik"
  # in the SocialApp the init container writes.
  allowed_redirect_uris = [
    {
      matching_mode     = "strict"
      url               = "https://${local.host}/accounts/oidc/${local.oidc_provider_id}/login/callback/"
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

resource "authentik_application" "glitchtip" {
  name               = "GlitchTip"
  slug               = "glitchtip"
  protocol_provider  = authentik_provider_oauth2.glitchtip.id
  meta_launch_url    = "https://${local.host}"
  policy_engine_mode = "any"
}

# A group membership check, as app-access-guard.tf in the authentik stack
# requires under policy_engine_mode "any".
resource "authentik_policy_binding" "home_server_admins" {
  target = authentik_application.glitchtip.uuid
  group  = data.authentik_group.home_server_admins.id
  order  = 0
}
