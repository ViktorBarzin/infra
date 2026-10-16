# System settings (Admin > System > Settings), adopted 2026-10-16 to turn off
# `core_default_app_access` (ADR-0001, ~/code/docs/adr). With the flag off, an
# application with no policy bindings admits nobody, so a new application stays
# closed until it is bound to a group. app-access-guard.tf still fails the plan
# for an unbound application; this makes the server agree with it.
#
# The flag is read only by application-level policy engines
# (core/apps.py AppAccessWithoutBindings), not by flows or stages.
#
# Every attribute is set to its live value on purpose. The provider gives each
# one a default (default_token_duration defaults to minutes=30, live is
# hours=168) and Update sends a full PUT, so an attribute left out would be
# reset. The same goes for `flags`: all four keys are sent on every update.
# `footer_links` is left out because live is an empty list, which is what the
# provider sends when it is unset. `base_url` and `impersonation_require_reason`
# are not in the provider schema; the PUT omits them and the server keeps their
# live values. Delete is a no-op in the provider, so removing this resource
# leaves the settings as they are.
resource "authentik_system_settings" "settings" {
  avatars                      = "gravatar,initials"
  default_user_change_name     = true
  default_user_change_email    = false
  default_user_change_username = false
  event_retention              = "days=365"
  gdpr_compliance              = true
  impersonation                = true
  default_token_duration       = "hours=168"
  default_token_length         = 60
  reputation_lower_limit       = -5
  reputation_upper_limit       = 5
  pagination_default_page_size = 20
  pagination_max_page_size     = 100

  flags = jsonencode({
    core_default_app_access                = false
    enterprise_audit_include_expanded_diff = false
    flows_continuous_login                 = false
    flows_refresh_others                   = false
  })
}
