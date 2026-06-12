# Authentik OAuth2 provider for the TripIt App (the native Android Shell) —
# tripit ADR-0017, viktor/tripit#49. The Shell does an Authorization Code +
# PKCE login in the system browser and lands back in the app via the
# custom-scheme redirect; the backend validates the issued RS256 JWTs itself
# (AUTH_MODE=hybrid, tripit slice 2). client_type "public": an APK cannot keep
# a client secret, PKCE is the binding. The bearer-only ingress host this
# pairs with is module.ingress_api in main.tf.

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

# offline_access is what makes Authentik issue a refresh token — the Shell
# stores only that and re-derives short-lived access tokens. Looked up by
# scope_name (the managed identifier is version-dependent).
data "authentik_property_mapping_provider_scope" "offline_access" {
  scope_name = "offline_access"
}

resource "authentik_provider_oauth2" "tripit_app" {
  name        = "tripit-app"
  client_id   = "tripit-app"
  client_type = "public"

  authorization_flow = data.authentik_flow.default_authorization_implicit_consent.id
  invalidation_flow  = data.authentik_flow.default_provider_invalidation.id

  allowed_redirect_uris = [
    {
      matching_mode = "strict"
      url           = "me.viktorbarzin.tripit://callback"
    },
  ]

  access_token_validity      = "hours=1"
  refresh_token_validity     = "days=90"
  include_claims_in_id_token = true
  signing_key                = data.authentik_certificate_key_pair.signing.id

  property_mappings = [
    data.authentik_property_mapping_provider_scope.openid.id,
    data.authentik_property_mapping_provider_scope.profile.id,
    data.authentik_property_mapping_provider_scope.email.id,
    data.authentik_property_mapping_provider_scope.offline_access.id,
  ]
}

resource "authentik_application" "tripit_app" {
  name               = "TripIt App"
  slug               = "tripit-app"
  protocol_provider  = authentik_provider_oauth2.tripit_app.id
  meta_launch_url    = "https://tripit.viktorbarzin.me"
  policy_engine_mode = "any"
}
