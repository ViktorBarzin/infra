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

# NOTE: the two email-verification stages (enrollment + recovery) AND their flow
# bindings are deliberately NOT defined here — they live in an Authentik
# BLUEPRINT (tripit-email-blueprint.tf), applied server-side. Reason: the
# globally-pinned provider (goauthentik 2024.x, terragrunt.hcl) models
# EmailStage.token_expiry as an INTEGER, but the live server (2026.2.x) requires
# a duration STRING ("hours=24") and 400s any number — the provider cannot send
# a valid value (confirmed: even the unset default `30` is rejected). The
# blueprint is parsed by the server, which accepts the string. Bumping the
# provider would be a global terragrunt.hcl change that re-applies every platform
# stack and breaks 3 other authentik-using app stacks' lockfiles — out of all
# proportion to two stages. See tripit ADR-0020.

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
  # Run the username-from-email policy (below) at stage-execution time, when
  # prompt_data is populated — not at plan time. Mirrors guest.tf's pre-stage
  # context-mutation pattern.
  evaluate_on_plan     = false
  re_evaluate_policies = true
}

# Passwordless, email-only signup collects no username, but user_write aborts on
# an empty username ("Aborting write to empty username"). Derive the username
# from the entered email just before user_write runs. Mutating flow_plan.context
# is the canonical mutable path — a plain request.context mutation would not
# propagate to the stage (see guest.tf's pending_user note).
resource "authentik_policy_expression" "tripit_username_from_email" {
  name = "tripit-enrollment-username-from-email"
  expression = trimspace(<<-EOT
    pd = request.context["flow_plan"].context.setdefault("prompt_data", {})
    pd["username"] = pd.get("email", "")
    return True
  EOT
  )
}

resource "authentik_policy_binding" "tripit_username_before_write" {
  target = authentik_flow_stage_binding.tripit_enroll_20_write.id
  policy = authentik_policy_expression.tripit_username_from_email.id
  order  = 0
}

# order 30 (email-verification binding) is in tripit-email-blueprint.tf — see note above
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

# (recovery email-verification stage is in tripit-email-blueprint.tf — see note above)

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
# order 20 (email-verification binding) is in tripit-email-blueprint.tf — see note above
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
