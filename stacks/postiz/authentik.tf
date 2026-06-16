# Authentik OIDC for the Postiz UI (2026-06-16, issue #45).
#
# Postiz keeps the Authentik forward-auth outer gate (ingress auth="required")
# AND offers "Login with Authentik" via generic OIDC. Postiz cannot disable its
# own local-login endpoint, so forward-auth stays in front to keep that endpoint
# off the public internet; OIDC is the SSO path. Access is gated to the
# `Postiz Users` group (Viktor + Anca) bound to this application — non-members
# cannot complete the OIDC flow. confidential client (Postiz is a server-side
# web app and can hold the secret); the secret is passed into the Helm release.
#
# Provider/app/group pattern mirrors stacks/tripit/authentik.tf. RS256 signing
# key (the self-signed cert) — required or Authentik signs HS256 with an empty
# JWKS and token verification fails.

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

# Usernames in this Authentik instance ARE the user's email (see
# stacks/authentik/t3-users.tf). Viktor + Anca are the only Postiz users.
data "authentik_user" "viktor" {
  username = "vbarzin@gmail.com"
}

data "authentik_user" "anca" {
  username = "ancaelena98@gmail.com"
}

resource "authentik_provider_oauth2" "postiz" {
  name        = "postiz"
  client_id   = "postiz"
  client_type = "confidential"
  # sub = the user's email (stable). Postiz keys OIDC accounts by the subject;
  # an email sub keeps Anca's and Viktor's identities stable across logins.
  sub_mode = "user_email"

  authorization_flow = data.authentik_flow.default_authorization_implicit_consent.id
  invalidation_flow  = data.authentik_flow.default_provider_invalidation.id

  # Postiz hardcodes its OIDC redirect to ${FRONTEND_URL}/settings.
  allowed_redirect_uris = [
    {
      matching_mode = "strict"
      url           = "https://postiz.viktorbarzin.me/settings"
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

resource "authentik_application" "postiz" {
  name              = "Postiz"
  slug              = "postiz"
  protocol_provider = authentik_provider_oauth2.postiz.id
  meta_launch_url   = "https://postiz.viktorbarzin.me"
  # "any" + at least one binding => only members of a bound group get access.
  policy_engine_mode = "any"
}

# Access gate: only these two users may complete the Postiz OIDC flow.
resource "authentik_group" "postiz_users" {
  name = "Postiz Users"
  users = [
    data.authentik_user.viktor.id,
    data.authentik_user.anca.id,
  ]
}

resource "authentik_policy_binding" "postiz_access" {
  target = authentik_application.postiz.uuid
  group  = authentik_group.postiz_users.id
  order  = 0
}
