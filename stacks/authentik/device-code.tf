# Device-code login for CLIs (ADR-0001 in ~/code/docs/adr, "API tokens").
#
# A CLI asks POST /application/o/device/ for a code and shows the person a URL
# and the code. The person opens https://authentik.viktorbarzin.me/device
# (login_required, so they sign in first), enters the code, passes the app's
# authorization flow and access bindings, and the CLI's polling of
# /application/o/token/ returns tokens.
#
# /device answers 404 until the brand names a device-code flow; it was null
# until this file. The flow needs no stages of its own: DeviceEntryView plans
# it with allow_empty_flows and appends the code-entry stage itself
# (providers/oauth2/views/device_init.py, 2026.8.4). Designation and
# authentication follow the Authentik docs.
#
# Each app's OAuth2 provider still has to allow the grant:
#   grant_types = [..., "urn:ietf:params:oauth:grant-type:device_code"]
# The provider pin reached 2026.8.0 on 2026-10-16 (terragrunt.hcl), which has
# `grant_types` on authentik_provider_oauth2; the first release with it is
# 2026.5.0. That setting belongs to the app's provider resource, not here.

resource "authentik_flow" "device_code" {
  name           = "device-code"
  slug           = "device-code"
  title          = "Sign in on a device"
  designation    = "stage_configuration"
  authentication = "require_authenticated"
}

# The default brand ("authentik-default", the only brand) was UI-managed until
# 2026-10-16, when it was imported (pk efe8ee42-945e-4731-a499-e4ee355c83b0).
# Only flow_device_code is managed here; every other field stays as it is live.
# Update is a full PUT of the fields this provider knows, and with
# ignore_changes those are sent with the values the import read back. Fields
# the provider does not know (flow_user_switch, flow_request,
# branding_map_tiles) are left out of the request, and the server leaves
# omitted fields alone.
resource "authentik_brand" "default" {
  domain           = "authentik-default"
  default          = true
  flow_device_code = authentik_flow.device_code.uuid

  lifecycle {
    ignore_changes = [
      attributes,
      branding_custom_css,
      branding_default_flow_background,
      branding_favicon,
      branding_logo,
      branding_title,
      client_certificates,
      default_application,
      flow_authentication,
      flow_invalidation,
      flow_lockdown,
      flow_recovery,
      flow_unenrollment,
      flow_user_settings,
      web_certificate,
    ]
  }
}
