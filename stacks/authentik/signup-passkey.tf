# Passkey signup without a social provider (infra#87, infra#51 story 18).
#
# The third door into the homelab, alongside social signup and recovery. Given
# out as its own URL with the invite code rather than added to signup-start,
# Viktor's call: signup-start is a single Identification stage rendering the
# three provider buttons and cannot show a fourth option beside them, an
# enrollment flow cannot branch, and putting a chooser in front would add a
# click to the route every existing account came through in order to serve a
# route nobody has needed yet.
#
#   /if/flow/signup-passkey/
#     order 10  prompt        email + invite code, gated by validate-invite-code
#     order 20  user write    creates the user INACTIVE
#     order 30  email verify  link activates the user (activate_user_on_success)
#     order 40  passkey setup discoverable credential
#     order 50  login         assign-invite-group adds the group + consumes the code
#
# IDENTITY IS VERIFIED, not self-asserted — also Viktor's call, and the reason
# this is worth building at all. Story 18 asked for signup with "no external
# redirect", and the literal reading of that is invite code plus passkey and
# nothing else. That would have produced the first account here whose address
# nobody has proved, unrecoverable and unreachable. The email round trip is a
# redirect of a different kind, and it buys an address as trustworthy as the one
# a provider hands over.
#
# WHY THIS IS CHEAP NOW: the recovery flow built the same shape and it is
# already driven end to end, so the stages, the email path and the WebAuthn
# enrolment are known-good rather than hoped-for.

# --- Prompt: email + invite code ---------------------------------------------
#
# Its own fields rather than reusing invite-flow.tf's invite-code-field. That
# one is wired into the social flow, so a wording or ordering change here would
# silently alter the page every social invitee sees.

resource "authentik_stage_prompt_field" "signup_passkey_email" {
  name        = "signup-passkey-email-field"
  field_key   = "email"
  label       = "Email address"
  type        = "email"
  required    = true
  placeholder = "you@example.com"
  sub_text    = "We send a confirmation link here. It is also how you get back in if you lose your passkey."
  order       = 100
}

resource "authentik_stage_prompt_field" "signup_passkey_code" {
  name        = "signup-passkey-code-field"
  field_key   = "invite_code"
  label       = "Invite code"
  type        = "text"
  required    = true
  placeholder = "e.g. R7K-M4Q"
  sub_text    = "Case- and dash-insensitive."
  order       = 200
}

# validate-invite-code (invite-flow.tf) is REUSED deliberately, not copied: it is
# the single gate that decides whether an invite is real, and a second copy would
# be a second thing to keep correct. It returns False on a bad or expired code,
# which rejects the prompt so no user row is written without a valid invite, and
# it stamps attributes.invite_group for the login stage to read.
#
# It also sets a username, falling back to the typed email — which is exactly
# what this flow provides, unlike a source enrollment where no username exists.
resource "authentik_stage_prompt" "signup_passkey_prompt" {
  name = "signup-passkey-prompt"
  fields = [
    authentik_stage_prompt_field.signup_passkey_email.id,
    authentik_stage_prompt_field.signup_passkey_code.id,
  ]
  validation_policies = [authentik_policy_expression.validate_invite_code.id]
}

# --- User write: INACTIVE until the email is confirmed -----------------------
#
# create_users_as_inactive is the whole mechanism. The row is written here so
# the email stage has a user to send to and a token to bind, but the account
# cannot be used until the link is clicked, so an unverified address never
# becomes a working account. Its own stage rather than
# default-source-enrollment-write, which creates users ACTIVE (correct there —
# a provider has already verified the address).
resource "authentik_stage_user_write" "signup_passkey_write" {
  name                     = "signup-passkey-write"
  create_users_as_inactive = true
  user_creation_mode       = "always_create"
  user_type                = "internal"
}

# --- Email verification ------------------------------------------------------
resource "authentik_stage_email" "signup_passkey_verify" {
  name                = "signup-passkey-verify"
  use_global_settings = true
  # Activates the inactive row written above when the link is followed. This is
  # the step that turns a typed address into a verified one.
  activate_user_on_success = true
  subject                  = "Confirm your account"
  # account_confirmation.html is the RIGHT template here — it opens "Welcome!"
  # with a "Confirm Account" button, which is what this is. The recovery flow
  # reuses password_reset.html instead and has to live with wrong wording,
  # because neither stock template fits regaining access.
  template = "email/account_confirmation.html"
  # Settable at last: the provider floor moved to ~> 2025.8 (resolving 2025.12.1),
  # where token_expiry is a string. Under the previous 2024.12.1 it was typed as a
  # NUMBER and the server rejected every value, which is why recovery-email still
  # runs on authentik's minutes=30 default.
  token_expiry = "hours=1"
}

# --- Flow --------------------------------------------------------------------
resource "authentik_flow" "signup_passkey" {
  # depends_on so the flow is the LAST object created. On 2026-09-02 an apply
  # that failed midway through the recovery flow left a reachable, half-built
  # flow that granted a session with no email proof. A flow is reachable at its
  # slug URL whether or not anything links to it, so a stage failure must leave
  # unreferenced stages, never a live flow.
  depends_on = [
    authentik_stage_prompt.signup_passkey_prompt,
    authentik_stage_user_write.signup_passkey_write,
    authentik_stage_email.signup_passkey_verify,
    authentik_stage_authenticator_webauthn.signup_passkey,
    data.authentik_stage.default_authentication_login,
  ]

  name           = "signup-passkey"
  slug           = "signup-passkey"
  title          = "Create your account"
  designation    = "enrollment"
  authentication = "require_unauthenticated"
}

resource "authentik_flow_stage_binding" "spk_prompt" {
  target               = authentik_flow.signup_passkey.uuid
  stage                = authentik_stage_prompt.signup_passkey_prompt.id
  order                = 10
  evaluate_on_plan     = true
  re_evaluate_policies = true
}

resource "authentik_flow_stage_binding" "spk_write" {
  target               = authentik_flow.signup_passkey.uuid
  stage                = authentik_stage_user_write.signup_passkey_write.id
  order                = 20
  evaluate_on_plan     = true
  re_evaluate_policies = true
}

resource "authentik_flow_stage_binding" "spk_verify" {
  target               = authentik_flow.signup_passkey.uuid
  stage                = authentik_stage_email.signup_passkey_verify.id
  order                = 30
  evaluate_on_plan     = true
  re_evaluate_policies = true
}

# The same WebAuthn stage the social flow uses: user_verification and
# resident_key both required, so the credential is discoverable and can later be
# the whole login. Shared on purpose here — this IS signup, so the two doors
# should enrol identically; diverging would be a bug, not a feature.
resource "authentik_flow_stage_binding" "spk_passkey" {
  target = authentik_flow.signup_passkey.uuid
  stage  = authentik_stage_authenticator_webauthn.signup_passkey.id
  order  = 40
  # Both evaluation modes off is rejected by authentik with
  # "Either evaluation on plan or evaluation on run must be enabled" (400).
  evaluate_on_plan     = true
  re_evaluate_policies = false
}

resource "authentik_flow_stage_binding" "spk_login" {
  target               = authentik_flow.signup_passkey.uuid
  stage                = data.authentik_stage.default_authentication_login.id
  order                = 50
  evaluate_on_plan     = false
  re_evaluate_policies = true
}

# Same group assignment the social flow uses, bound to the login stage: it reads
# attributes.invite_group off the saved user (prompt_data does not reliably
# survive to the login stage) and consumes the invitation.
resource "authentik_policy_binding" "spk_assign_invite_group" {
  target = authentik_flow_stage_binding.spk_login.id
  policy = authentik_policy_expression.assign_invite_group.id
  order  = 0
}
