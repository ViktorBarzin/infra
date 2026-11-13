# cloud-cli: the sign-in client for Cloud's CLI and MCP clients (Cloud v1
# plan, "How do agents sign in?"; docs/architecture/cloud.md, "Agent
# sign-in").
#
# The console's provider (module.console) is confidential. A device-code token
# from it cannot be refreshed without the client secret, which a CLI must not
# hold, so `cloud login` would be needed every 15 minutes. This second client
# is public, allows only the device code and refresh token grants, and issues
# 1-hour access tokens with 30-day refresh tokens (offline_access).
#
# The API accepts its tokens through API_TOKEN_AUDIENCES (deploy_rules.tf).
# Same issuer mode as the console (per_provider), so its issuer is
# <authentik>/application/o/cloud-cli/; the token verifier must accept that
# issuer too, which M6's code adds (AGENT_OIDC_DISCOVERY_URL). Same sub_mode,
# so a person has the same `sub` on both clients and is one User.
#
# Who may sign in: the same groups as the console. The API checks Cloud
# membership again on every request.

# Device-code phishing. Anyone can start a device authorization for this
# public client: it needs only the client_id. Authentik answers with
# verification_uri_complete (/device?code=XXXX), and a signed-in person who
# opens that link runs this provider's authorization flow, then the device
# code is granted to whoever started it (DeviceEntryView, CodeValidatorView in
# authentik 2026.8). With the implicit-consent flow nothing would stand
# between the click and the grant, so an invited User could send an Operator
# a link and get the Operator's tokens. This flow always shows a consent
# screen that names "Cloud CLI", every time: the stock explicit-consent flow's
# stage remembers consent for weeks (mode expiring, checked live 2026-11-13),
# which would make every later link one click again.
resource "authentik_stage_consent" "cloud_cli" {
  name = "cloud-cli-consent"
  mode = "always_require"
}

resource "authentik_flow" "cloud_cli_authorization" {
  name           = "Cloud CLI authorization"
  slug           = "cloud-cli-authorization"
  title          = "Allow Cloud CLI to act as you"
  designation    = "authorization"
  authentication = "require_authenticated"
}

resource "authentik_flow_stage_binding" "cloud_cli_consent" {
  target = authentik_flow.cloud_cli_authorization.uuid
  stage  = authentik_stage_consent.cloud_cli.id
  order  = 0
}

data "authentik_flow" "cli_invalidation" {
  slug = "default-provider-invalidation-flow"
}

data "authentik_certificate_key_pair" "cli_signing" {
  name = "authentik Self-signed Certificate"
}

data "authentik_property_mapping_provider_scope" "cli_openid" {
  managed = "goauthentik.io/providers/oauth2/scope-openid"
}

data "authentik_property_mapping_provider_scope" "cli_profile" {
  managed = "goauthentik.io/providers/oauth2/scope-profile"
}

data "authentik_property_mapping_provider_scope" "cli_email" {
  managed = "goauthentik.io/providers/oauth2/scope-email"
}

# offline_access makes Authentik issue a refresh token (as in stacks/tripit).
data "authentik_property_mapping_provider_scope" "cli_offline_access" {
  scope_name = "offline_access"
}

data "authentik_group" "cli_home_server_admins" {
  name          = "Home Server Admins"
  include_users = false
}

resource "authentik_provider_oauth2" "cloud_cli" {
  name        = local.cloud_cli_client_id
  client_id   = local.cloud_cli_client_id
  client_type = "public"

  authorization_flow = authentik_flow.cloud_cli_authorization.uuid
  invalidation_flow  = data.authentik_flow.cli_invalidation.id

  # Same as the console's provider (modules/kubernetes/tanstack_app).
  sub_mode    = "hashed_user_id"
  issuer_mode = "per_provider"
  signing_key = data.authentik_certificate_key_pair.cli_signing.id

  access_token_validity      = "hours=1"
  refresh_token_validity     = "days=30"
  include_claims_in_id_token = true

  property_mappings = [
    data.authentik_property_mapping_provider_scope.cli_openid.id,
    data.authentik_property_mapping_provider_scope.cli_profile.id,
    data.authentik_property_mapping_provider_scope.cli_email.id,
    data.authentik_property_mapping_provider_scope.cli_offline_access.id,
  ]

  # No redirect URIs: device code needs none, and without authorization_code
  # nothing can be redirected.
  grant_types = ["urn:ietf:params:oauth:grant-type:device_code", "refresh_token"]
}

resource "authentik_application" "cloud_cli" {
  name               = "Cloud CLI"
  slug               = local.cloud_cli_client_id
  protocol_provider  = authentik_provider_oauth2.cloud_cli.id
  policy_engine_mode = "any"
  meta_description   = "Sign-in for Cloud's CLI and MCP clients (device code)."
  # Authentik's idiom for "not launchable": keeps a credential-only client
  # out of the user library.
  meta_launch_url = "blank://blank"
}

# Group membership checks only, as stacks/authentik app-access-guard.tf
# requires under policy_engine_mode "any".
resource "authentik_policy_binding" "cloud_cli_users" {
  target = authentik_application.cloud_cli.uuid
  group  = module.console.users_group_id
  order  = 0
}

resource "authentik_policy_binding" "cloud_cli_operators" {
  target = authentik_application.cloud_cli.uuid
  group  = module.console.admins_group_id
  order  = 1
}

resource "authentik_policy_binding" "cloud_cli_home_server_admins" {
  target = authentik_application.cloud_cli.uuid
  group  = data.authentik_group.cli_home_server_admins.id
  order  = 2
}
