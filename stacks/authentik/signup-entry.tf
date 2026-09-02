# The "Sign up" target for default-authentication-identification (infra#51,
# stories 1 and 2).
#
# Until now `default-authentication-identification.enrollment_flow` was null, so
# an invitee with no account reached the login page and had no way forward at
# all — the invite flow was only reachable by someone already mid-Google
# redirect. Neither existing enrollment flow can be pointed at directly:
# `invitation-enrollment` opens with an InvitationStage whose
# continue_flow_without_invitation is false, so a no-token entry is denied; and
# `social-signup` entered directly has no source connection, so its
# invite-code policy falls through and the write stage mints an emailless
# `guest-<code>` account.
#
# So this is a deliberate one-stage flow: the sources-only identification
# screen. Clicking Google leaves for the source, whose own enrollment_flow
# (social-signup) then runs invite-code prompt -> write -> passkey ->
# login. Nothing else can live here — an enrollment flow cannot branch, and a
# source login abandons this plan on the redirect.
data "authentik_stage" "enrollment_identification" {
  # Runtime object (pk 122b953a-9370-4fec-b8a2-06e197af9693), already exactly
  # right and deliberately not edited: user_fields=[], password_stage=null,
  # sources=[google, github, facebook], show_source_labels=true.
  name = "enrollment-identification"
}

resource "authentik_flow" "signup_start" {
  name           = "Signup"
  slug           = "signup-start"
  title          = "Create your account"
  designation    = "enrollment"
  authentication = "require_unauthenticated"
}

resource "authentik_flow_stage_binding" "signup_start_identification" {
  target               = authentik_flow.signup_start.uuid
  stage                = data.authentik_stage.enrollment_identification.id
  order                = 10
  evaluate_on_plan     = false
  re_evaluate_policies = true
}
