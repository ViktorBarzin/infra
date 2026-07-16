# Authentik OIDC (SSO) for Stirling-PDF v2 (2026-07-16).
#
# Viktor asked to enable Stirling's user/login mode and link it to Authentik.
# Stirling v2 supports generic OIDC, so it is the OAuth2 client and Authentik is
# the IdP: one SSO login, users auto-provisioned on first login, no exposed
# local password page as the primary path. The ingress is auth="app" (Stirling
# is the gate) — NOT forward-auth — so the OIDC redirect/callback isn't
# intercepted. Access is gated by the "Stirling PDF Users" group bound to the
# application: only members can complete the flow.
#
# Provider/app/group pattern mirrors stacks/postiz/authentik.tf. RS256 signing
# key (the self-signed cert) is REQUIRED — otherwise Authentik signs HS256 with
# an empty JWKS and Stirling's token verification fails.

data "vault_kv_secret_v2" "authentik_tf" {
  mount = "secret"
  name  = "authentik"
}

provider "authentik" {
  url   = "https://authentik.viktorbarzin.me"
  token = data.vault_kv_secret_v2.authentik_tf.data["tf_api_token"]
}

data "authentik_flow" "default_authorization_implicit_consent" {
  slug = "default-provider-authorization-implicit-consent"
}

data "authentik_flow" "default_provider_invalidation" {
  slug = "default-provider-invalidation-flow"
}

data "authentik_certificate_key_pair" "signing" {
  name = "authentik Self-signed Certificate"
}

data "authentik_property_mapping_provider_scope" "openid" {
  managed = "goauthentik.io/providers/oauth2/scope-openid"
}

data "authentik_property_mapping_provider_scope" "profile" {
  managed = "goauthentik.io/providers/oauth2/scope-profile"
}

data "authentik_property_mapping_provider_scope" "email" {
  managed = "goauthentik.io/providers/oauth2/scope-email"
}

# Usernames in this Authentik instance ARE the user's email (stacks/authentik).
data "authentik_user" "viktor" {
  username = "vbarzin@gmail.com"
}

resource "authentik_provider_oauth2" "stirling_pdf" {
  name        = "stirling-pdf"
  client_id   = "stirling-pdf"
  client_type = "confidential" # server-side app; holds the secret
  # sub = the user's email (stable); Stirling keys OIDC users by useAsUsername=email.
  sub_mode = "user_email"

  authorization_flow = data.authentik_flow.default_authorization_implicit_consent.id
  invalidation_flow  = data.authentik_flow.default_provider_invalidation.id

  # Stirling (Spring Security) callback is {baseUrl}/login/oauth2/code/{provider},
  # where {provider} == security.oauth2.provider ("authentik", set in main.tf).
  allowed_redirect_uris = [
    {
      matching_mode = "strict"
      url           = "https://stirling-pdf.viktorbarzin.me/login/oauth2/code/authentik"
    },
  ]

  access_token_validity      = "hours=1"
  refresh_token_validity     = "days=30"
  include_claims_in_id_token = true
  signing_key                = data.authentik_certificate_key_pair.signing.id

  property_mappings = [
    data.authentik_property_mapping_provider_scope.openid.id,
    data.authentik_property_mapping_provider_scope.profile.id,
    data.authentik_property_mapping_provider_scope.email.id,
  ]
}

resource "authentik_application" "stirling_pdf" {
  name              = "Stirling PDF"
  slug              = "stirling-pdf" # => issuer https://authentik.viktorbarzin.me/application/o/stirling-pdf/
  protocol_provider = authentik_provider_oauth2.stirling_pdf.id
  meta_launch_url   = "https://stirling-pdf.viktorbarzin.me"
  meta_icon         = "https://stirling-pdf.viktorbarzin.me/favicon.ico"
  # "any" + at least one binding => only members of a bound group get access.
  policy_engine_mode = "any"
}

# Access gate: only members may complete the Stirling OIDC flow. Add more users
# here (or convert to an existing group) to grant access to family/others.
resource "authentik_group" "stirling_pdf_users" {
  name = "Stirling PDF Users"
  users = [
    data.authentik_user.viktor.id,
  ]
}

resource "authentik_policy_binding" "stirling_pdf_access" {
  target = authentik_application.stirling_pdf.uuid
  group  = authentik_group.stirling_pdf_users.id
  order  = 0
}
