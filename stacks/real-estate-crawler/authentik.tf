# Authentik OAuth2 provider and application for Wrongmove's "Log in with
# Authentik" (SSO) button. Both were made by hand in the Authentik UI and
# adopted into Terraform on 2026-11-14 (import {} blocks, since removed),
# matching the live objects field for field. Who may sign in is decided by
# the "Wrongmove Users" group binding in
# stacks/authentik/app-access-bindings.tf, not here.
#
# A public/PKCE client: the frontend runs the authorize flow and the backend
# only checks the token audience (OIDC_CLIENT_ID in main.tf, the same id as
# client_id below). Authentik still stores a generated client_secret, which is
# left unset here so Terraform keeps the stored value as read on import.

data "vault_kv_secret_v2" "authentik_tf" {
  mount = "secret"
  name  = "authentik"
}

provider "authentik" {
  url   = "https://authentik.viktorbarzin.me"
  token = data.vault_kv_secret_v2.authentik_tf.data["tf_api_token"]
}

# Flows are pinned to their UUIDs, as in stacks/tripit/authentik.tf: the flow
# data source has resolved null in CI before and blocked every apply.
#   6e345b83-... = default-provider-authorization-implicit-consent
#   3cb29d31-... = default-invalidation-flow (not default-provider-invalidation-flow;
#                  that is what the hand-made provider was created with)

data "authentik_certificate_key_pair" "signing" {
  name = "authentik Self-signed Certificate"
}

data "authentik_property_mapping_provider_scope" "openid" {
  managed = "goauthentik.io/providers/oauth2/scope-openid"
}

data "authentik_property_mapping_provider_scope" "email" {
  managed = "goauthentik.io/providers/oauth2/scope-email"
}

data "authentik_property_mapping_provider_scope" "profile" {
  managed = "goauthentik.io/providers/oauth2/scope-profile"
}

resource "authentik_provider_oauth2" "wrongmove" {
  name        = "Provider for wrongmove"
  client_id   = "5AJKRgcdgVm1OyApBzFkadDFfStW9a555zwv2MOe"
  client_type = "public"
  # sub = Authentik's hashed user id, which is also the telemetry Person id
  # (infra ADR-0041). Changing it would re-key every SSO user.
  sub_mode    = "hashed_user_id"
  issuer_mode = "per_provider"

  authorization_flow = "6e345b83-0b5d-44f5-9bda-bcd970932f39"
  invalidation_flow  = "3cb29d31-864f-4c5d-ae25-9eafa2d02b53"

  # The full list the hand-made provider carries. Kept as is so adoption
  # changes nothing; narrowing it is a separate decision.
  grant_types = [
    "authorization_code",
    "hybrid",
    "implicit",
    "client_credentials",
    "password",
    "urn:ietf:params:oauth:grant-type:device_code",
    "refresh_token",
  ]

  allowed_redirect_uris = [
    {
      matching_mode     = "strict"
      url               = "https://wrongmove.viktorbarzin.me/callback"
      redirect_uri_type = "authorization"
    },
    {
      matching_mode     = "strict"
      url               = "https://devvm.viktorbarzin.lan/callback"
      redirect_uri_type = "authorization"
    },
    {
      matching_mode     = "strict"
      url               = "https://localhost/callback"
      redirect_uri_type = "authorization"
    },
  ]

  access_code_validity       = "minutes=1"
  access_token_validity      = "hours=168"
  refresh_token_validity     = "days=30"
  refresh_token_threshold    = "seconds=0"
  include_claims_in_id_token = true
  signing_key                = data.authentik_certificate_key_pair.signing.id
  logout_method              = "backchannel"

  # Tokens issued by the Google source are accepted on behalf of the user.
  jwt_federation_sources = ["4750e835-4914-4355-8018-f7b20b50c357"] # source "google"

  property_mappings = [
    data.authentik_property_mapping_provider_scope.openid.id,
    data.authentik_property_mapping_provider_scope.email.id,
    data.authentik_property_mapping_provider_scope.profile.id,
  ]
}

resource "authentik_application" "wrongmove" {
  name               = "wrongmove"
  slug               = "wrongmove"
  protocol_provider  = authentik_provider_oauth2.wrongmove.id
  policy_engine_mode = "any"
}
