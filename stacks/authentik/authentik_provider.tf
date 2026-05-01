# goauthentik/authentik Terraform provider.
#
# Adopted 2026-04-18 (Wave 6a of the state-drift consolidation plan) to bring
# the catch-all Proxy Provider — previously managed only via the Authentik UI
# — under Terraform management. API token lives in Vault
# `secret/authentik/tf_api_token` (token identifier `terraform-infra-stack`,
# intent API, user akadmin, no expiry). Required-providers declaration sits
# in the central terragrunt.hcl so every stack has it available; only this
# stack configures a provider block.

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

# -----------------------------------------------------------------------------
# Catch-all Proxy Provider + Application.
#
# Created via the Authentik UI ~a year ago; adopted into Terraform 2026-04-18
# (Wave 6a). The proxy provider is consumed by the embedded outpost
# (uuid 0eecac07-97c7-443c-8925-05f2f4fe3e47) via an outpost-level binding
# that stays in the UI — it's a single toggle with no drift risk.
# -----------------------------------------------------------------------------

resource "authentik_application" "catchall" {
  name              = "Domain wide catch all"
  slug              = "domain-wide-catch-all"
  protocol_provider = authentik_provider_proxy.catchall.id
  lifecycle {
    ignore_changes = [meta_description, meta_launch_url, meta_icon, group, backchannel_providers, policy_engine_mode, open_in_new_tab]
  }
}

resource "authentik_provider_proxy" "catchall" {
  name          = "Provider for Domain wide catch all"
  mode          = "forward_domain"
  external_host = "https://authentik.viktorbarzin.me"
  cookie_domain = "viktorbarzin.me"
  # Flow UUIDs resolved dynamically so a flow re-creation (keeping the slug)
  # doesn't require an HCL edit.
  authorization_flow = data.authentik_flow.default_authorization_implicit_consent.id
  invalidation_flow  = data.authentik_flow.default_provider_invalidation.id
  lifecycle {
    ignore_changes = [property_mappings, jwt_federation_sources, skip_path_regex, internal_host, basic_auth_enabled, basic_auth_password_attribute, basic_auth_username_attribute, intercept_header_auth, access_token_validity]
  }
}

# -----------------------------------------------------------------------------
# Default User Login stage — bound to default-authentication-flow.
# Adopted into Terraform 2026-05-01 to set session_duration=weeks=4 so users
# stay logged in across browser restarts. There is no Brand.session_duration
# in authentik 2026.2.x — UserLoginStage is the correct knob.
# -----------------------------------------------------------------------------

data "authentik_stage" "default_authentication_login" {
  name = "default-authentication-login"
}

import {
  to = authentik_stage_user_login.default_login
  id = data.authentik_stage.default_authentication_login.id
}

resource "authentik_stage_user_login" "default_login" {
  name             = "default-authentication-login"
  session_duration = "weeks=4"
  lifecycle {
    # Pin only session_duration; everything else stays UI-managed so the
    # plan doesn't churn unrelated knobs (e.g. remember_me_offset toggles).
    ignore_changes = [
      remember_me_offset,
      terminate_other_sessions,
      geoip_binding,
      network_binding,
    ]
  }
}
