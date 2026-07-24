# Proxy Users — the group that scopes an account to ONLY the proxy remote-browser
# service. The admin-services-restriction policy (admin-services-restriction.tf)
# returns True for these members only on proxy.viktorbarzin.me and denies every
# other Authentik-gated host. Add a person here (after they log in once via
# Google social login, which auto-provisions their account) to give them
# proxy-only access.
#
# NOTE: the self-signup INVITE LINK (an enrollment flow + invitation stage that
# auto-adds new accounts to this group via authentik_stage_user_write's
# create_users_group) is the planned next increment — see the design doc.
resource "authentik_group" "proxy_users" {
  name = "Proxy Users"
}

# --- Self-signup invite link -------------------------------------------------
# An invite-only enrollment flow: whoever opens the invite URL creates an
# account and is auto-added to "Proxy Users" (user_write.create_users_group),
# so the admin-services-restriction policy restricts them to ONLY
# proxy.viktorbarzin.me. Reusable link (single_use=false) — share with anyone
# you trust; delete the invitation to revoke the link.
#
# Invite URL: https://authentik.viktorbarzin.me/if/flow/proxy-signup/?itoken=<invitation id>

resource "authentik_flow" "proxy_enrollment" {
  name           = "proxy-signup"
  title          = "Sign up — Proxy Browser"
  slug           = "proxy-signup"
  designation    = "enrollment"
  authentication = "require_unauthenticated"
}

resource "authentik_stage_invitation" "proxy_invite" {
  name                             = "proxy-invitation-stage"
  continue_flow_without_invitation = false # invite-only: no token -> flow denies
}

resource "authentik_stage_prompt_field" "proxy_username" {
  name      = "proxy-username"
  field_key = "username"
  label     = "Username"
  type      = "username" # explicit username field avoids the empty-username user_write abort (memory #6165)
  order     = 0
  required  = true
}
resource "authentik_stage_prompt_field" "proxy_email" {
  name      = "proxy-email"
  field_key = "email"
  label     = "Email"
  type      = "email"
  order     = 100
  required  = true
}
resource "authentik_stage_prompt_field" "proxy_password" {
  name      = "proxy-password"
  field_key = "password"
  label     = "Password"
  type      = "password"
  order     = 200
  required  = true
}
resource "authentik_stage_prompt_field" "proxy_password_repeat" {
  name      = "proxy-password-repeat"
  field_key = "password_repeat"
  label     = "Confirm password"
  type      = "password"
  order     = 300
  required  = true
}

resource "authentik_stage_prompt" "proxy_enroll_prompt" {
  name = "proxy-enroll-prompt"
  fields = [
    authentik_stage_prompt_field.proxy_username.id,
    authentik_stage_prompt_field.proxy_email.id,
    authentik_stage_prompt_field.proxy_password.id,
    authentik_stage_prompt_field.proxy_password_repeat.id,
  ]
}

resource "authentik_stage_user_write" "proxy_enroll_write" {
  name                     = "proxy-enroll-write"
  create_users_as_inactive = false
  create_users_group       = authentik_group.proxy_users.id # <- scopes every signup to proxy-only
  user_creation_mode       = "always_create"
  user_type                = "external"
}

resource "authentik_stage_user_login" "proxy_enroll_login" {
  name             = "proxy-enroll-login"
  session_duration = "days=30"
}

resource "authentik_flow_stage_binding" "proxy_b_invite" {
  target = authentik_flow.proxy_enrollment.uuid
  stage  = authentik_stage_invitation.proxy_invite.id
  order  = 10
}
resource "authentik_flow_stage_binding" "proxy_b_prompt" {
  target = authentik_flow.proxy_enrollment.uuid
  stage  = authentik_stage_prompt.proxy_enroll_prompt.id
  order  = 20
}
resource "authentik_flow_stage_binding" "proxy_b_write" {
  target = authentik_flow.proxy_enrollment.uuid
  stage  = authentik_stage_user_write.proxy_enroll_write.id
  order  = 30
}
resource "authentik_flow_stage_binding" "proxy_b_login" {
  target = authentik_flow.proxy_enrollment.uuid
  stage  = authentik_stage_user_login.proxy_enroll_login.id
  order  = 40
}

# The invitation TOKEN itself is a RUNTIME object (the goauthentik provider has
# no invitation resource — only the stage above), created via the Authentik API
# against this flow. Create/rotate it with:
#   POST /api/v3/stages/invitation/invitations/  { "name": "...", "flow": "<proxy-signup flow uuid>", "single_use": false }
# The invite URL is then:
#   https://authentik.viktorbarzin.me/if/flow/proxy-signup/?itoken=<invitation pk>
