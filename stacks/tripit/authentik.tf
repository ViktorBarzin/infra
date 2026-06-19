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

# NOTE: invalidation_flow is pinned to the literal UUID on tripit_app below,
# not read via this data source — under the goauthentik 2024.x provider vs
# 2026.2 server skew the flow data source intermittently resolves null in CI
# (pipeline 244: "invalidation_flow is required, but no definition was found"),
# which silently blocked every tripit-stack apply. The pinned UUID is exactly
# what this slug ("default-provider-invalidation-flow") resolves to.

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
  # sub = the user's EMAIL, not the default hashed_user_id: tripit prod users
  # are email-keyed (forwardauth provisioned id == email), and the backend's
  # hybrid bearer arm must resolve the SAME user row, not mint a hash-keyed
  # twin (review finding, tripit #50).
  sub_mode = "user_email"

  authorization_flow = data.authentik_flow.default_authorization_implicit_consent.id
  invalidation_flow  = "b0a43377-0fa6-45d1-89fc-ed298bb1bb53" # default-provider-invalidation-flow (pinned; see note above)

  allowed_redirect_uris = [
    {
      matching_mode = "strict"
      url           = "me.viktorbarzin.tripit://callback"
    },
    {
      # "Log in with Authentik" on the website: TripIt is the OIDC client and
      # mints its own session on callback (tripit ADR-0028, #90). Same public
      # tripit-app provider as the Shell — just the web redirect URI added.
      matching_mode = "strict"
      url           = "https://tripit.viktorbarzin.me/api/auth/callback/authentik"
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
