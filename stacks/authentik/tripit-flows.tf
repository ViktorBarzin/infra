# =============================================================================
# TripIt external-user self-service flows (tripit ADR-0020).
#
# Public, passwordless self-signup for external users (people Viktor shares
# trips with). Three concerns:
#
#   * tripit-enrollment — open registration with email + passkey. Creates an
#     INACTIVE external user in "TripIt External", then an email-verification
#     stage ACTIVATES it. Email verification is the SECURITY BOUNDARY: tripit's
#     backend trusts the X-authentik-email header (AUTH_MODE=hybrid), so a user
#     must not be able to enroll under an address they don't control. Creating
#     the user inactive and activating ONLY on a clicked verification link
#     enforces that — an attacker who enters someone else's address produces an
#     inactive account that never activates and can never log in.
#
#   * passwordless login — already provided by the built-in `webauthn` flow,
#     wired as passwordless_flow on the default login page's identification
#     stage. No new flow needed; external users with a passkey log in there.
#
#   * tripit-recovery — email-anchored: prove inbox ownership, then register a
#     NEW passkey (the "lost my device" path; multi-passkey per ADR-0020). NOT
#     wired into the brand/global login flow (that would change ADMIN recovery
#     behaviour) — reached via its own /if/flow/tripit-recovery/ URL.
#
# Fence: the "TripIt External" group (tripit-external.tf) + the prepended branch
# in admin-services-restriction.tf admit these users to tripit.viktorbarzin.me
# ONLY and deny every other *.viktorbarzin.me forward-auth host. Email is sent
# via the global SMTP settings wired in modules/authentik/values.yaml
# (noreply@viktorbarzin.me through mail.viktorbarzin.me).
# =============================================================================

# ---- Shared stages (used by both enrollment and recovery) -------------------

# Discoverable (resident) credential => usernameless passwordless login via the
# built-in `webauthn` flow, which has no identification stage and so REQUIRES a
# discoverable credential to resolve the user. "required" guarantees that;
# every modern passkey authenticator supports it.
resource "authentik_stage_authenticator_webauthn" "tripit_passkey" {
  name                     = "tripit-passkey-setup"
  resident_key_requirement = "required"
  user_verification        = "preferred"
}

resource "authentik_stage_user_login" "tripit_login" {
  name             = "tripit-login"
  session_duration = "weeks=4"
}

# ---- Enrollment -------------------------------------------------------------

resource "authentik_stage_prompt_field" "tripit_enroll_email" {
  name      = "tripit-enroll-email"
  field_key = "email"
  label     = "Email"
  type      = "email"
  required  = true
  order     = 0
}

resource "authentik_stage_prompt_field" "tripit_enroll_name" {
  name      = "tripit-enroll-name"
  field_key = "name"
  label     = "Full name"
  type      = "text"
  required  = true
  order     = 1
}

resource "authentik_stage_prompt" "tripit_enroll_prompt" {
  name = "tripit-enrollment-prompt"
  fields = [
    authentik_stage_prompt_field.tripit_enroll_email.id,
    authentik_stage_prompt_field.tripit_enroll_name.id,
  ]
}

resource "authentik_stage_user_write" "tripit_enroll_write" {
  name = "tripit-enrollment-write"
  # Created INACTIVE: only the email-verification stage (below) activates it.
  create_users_as_inactive = true
  # Land in the fenced group (tripit-only via admin-services-restriction).
  create_users_group = authentik_group.tripit_external.id
  user_type          = "external"
  # Open registration: ALWAYS create a fresh user; never attach to / mutate an
  # existing one. There is no identification stage before this, so there is no
  # pending user to hijack — this is belt-and-suspenders against account takeover.
  user_creation_mode = "always_create"
}

resource "authentik_stage_email" "tripit_enroll_verify" {
  name = "tripit-enrollment-verify"
  # Use AUTHENTIK_EMAIL__* (noreply@viktorbarzin.me via mail.viktorbarzin.me).
  use_global_settings = true
  # THE security gate: a user becomes active (and thus loginable / trusted by
  # tripit's X-authentik-email) only after clicking the link sent to their inbox.
  activate_user_on_success = true
  subject                  = "Confirm your TripIt account"
  template                 = "email/account_confirmation.html"
  token_expiry             = 1440 # minutes = 24h
}

resource "authentik_flow" "tripit_enrollment" {
  name           = "Sign up for TripIt"
  title          = "Create your TripIt account"
  slug           = "tripit-enrollment"
  designation    = "enrollment"
  authentication = "require_unauthenticated"
}

# prompt -> write(inactive) -> verify(activate) -> passkey -> login
resource "authentik_flow_stage_binding" "tripit_enroll_10_prompt" {
  target = authentik_flow.tripit_enrollment.uuid
  stage  = authentik_stage_prompt.tripit_enroll_prompt.id
  order  = 10
}
resource "authentik_flow_stage_binding" "tripit_enroll_20_write" {
  target = authentik_flow.tripit_enrollment.uuid
  stage  = authentik_stage_user_write.tripit_enroll_write.id
  order  = 20
}
resource "authentik_flow_stage_binding" "tripit_enroll_30_verify" {
  target = authentik_flow.tripit_enrollment.uuid
  stage  = authentik_stage_email.tripit_enroll_verify.id
  order  = 30
}
resource "authentik_flow_stage_binding" "tripit_enroll_40_passkey" {
  target = authentik_flow.tripit_enrollment.uuid
  stage  = authentik_stage_authenticator_webauthn.tripit_passkey.id
  order  = 40
}
resource "authentik_flow_stage_binding" "tripit_enroll_50_login" {
  target = authentik_flow.tripit_enrollment.uuid
  stage  = authentik_stage_user_login.tripit_login.id
  order  = 50
}

# ---- Recovery (email-anchored, passwordless) --------------------------------

resource "authentik_stage_identification" "tripit_recover_ident" {
  name        = "tripit-recovery-identification"
  user_fields = ["email"]
  # Anti-enumeration: proceed even for an unknown address (no "user not found").
  pretend_user_exists = true
}

resource "authentik_stage_email" "tripit_recover_email" {
  name                = "tripit-recovery-email"
  use_global_settings = true
  subject             = "Recover your TripIt access"
  template            = "email/account_confirmation.html"
  token_expiry        = 60 # minutes = 1h
}

resource "authentik_flow" "tripit_recovery" {
  name           = "Recover TripIt access"
  title          = "Recover your TripIt account"
  slug           = "tripit-recovery"
  designation    = "recovery"
  authentication = "require_unauthenticated"
}

# identify(email) -> email(prove ownership) -> new passkey -> login
resource "authentik_flow_stage_binding" "tripit_recover_10_ident" {
  target = authentik_flow.tripit_recovery.uuid
  stage  = authentik_stage_identification.tripit_recover_ident.id
  order  = 10
}
resource "authentik_flow_stage_binding" "tripit_recover_20_email" {
  target = authentik_flow.tripit_recovery.uuid
  stage  = authentik_stage_email.tripit_recover_email.id
  order  = 20
}
resource "authentik_flow_stage_binding" "tripit_recover_30_passkey" {
  target = authentik_flow.tripit_recovery.uuid
  stage  = authentik_stage_authenticator_webauthn.tripit_passkey.id
  order  = 30
}
resource "authentik_flow_stage_binding" "tripit_recover_40_login" {
  target = authentik_flow.tripit_recovery.uuid
  stage  = authentik_stage_user_login.tripit_login.id
  order  = 40
}
