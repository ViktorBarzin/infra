# Self-service account recovery (infra#87, decided 2026-09-02).
#
# Until now there was NO recovery flow at all — `recovery_flow` on
# default-authentication-identification was null, so the login page carried no
# way back and every lost credential was a manual fix. That is fine for the six
# Google-backed accounts, which recover through Google, and not fine for the
# three local ones: anca.r.cristian10 holds a single iCloud Keychain passkey and
# nothing else.
#
# The chain ends in a NEW PASSKEY, not a password. Nothing here signs in with a
# password by choice (6 Google accounts, 4 registered passkeys), and a recovery
# path that mints a password would quietly add a second, permanent way in.
# Someone recovering is on a new device anyway, so enrolling a fresh
# authenticator is the natural act rather than an extra step.
#
#   recovery-identification -> recovery-email -> passkey setup -> login
#
# SUPERUSERS ARE DENIED, and that is load-bearing rather than tidiness. akadmin
# is a superuser in kubernetes-admins + Home Server Admins whose address
# akadmin@viktorbarzin.me has no alias, so it falls to the @viktorbarzin.me
# catch-all and lands in spam@viktorbarzin.me — a mailbox whose credential is
# referenced by four stacks. Without this policy, publishing a recovery flow
# would CREATE a path from that shared mailbox to cluster admin. Viktor's own
# account is also a superuser, but its address is his Google address, so email
# access there is already equivalent to Google login and adds nothing new.
# Recovering an admin account stays a manual act, deliberately.

# Its own identification stage. default-authentication-identification cannot be
# reused: it carries the three social sources and a password stage, which in a
# recovery context would offer routes that defeat the point.
resource "authentik_stage_identification" "recovery_identification" {
  name        = "recovery-identification"
  user_fields = ["email", "username"]
  # No password_stage, no sources — identify, then prove it by email.
  # pretend_user_exists matches the two existing identification stages, so the
  # form cannot be used to discover which addresses have accounts.
  pretend_user_exists = true
}

# token_expiry is deliberately NOT set. The provider is pinned ~> 2024.10 where
# the attribute is a NUMBER, while authentik 2026.8.1 requires a duration string
# ("hours=1") and rejects a number outright:
#   POST /stages/email/ -> 400
#   {"token_expiry":["60 is not in the correct format of 'hours=3;minutes=1'."]}
# Provider 2025.8.1 does type it as a string, but bumping the constraint moves
# every resource in the stack that gates all authentication, which is not a
# trade worth making for the gap between 30 and 60 minutes. So authentik's own
# default of minutes=30 applies, and this stays unmanaged until the provider is
# upgraded on its own merits.
resource "authentik_stage_email" "recovery_email" {
  name                     = "recovery-email"
  use_global_settings      = true
  activate_user_on_success = false
  subject                  = "Recover your access"
  # KNOWN COSMETIC GAP: neither stock template fits a passkey recovery.
  # password_reset.html says "requested to change your password ... set a new
  # password" with a "Reset Password" button, and account_confirmation.html
  # greets the person with "Welcome!" as though the account were new. This one
  # is the better of the two: right intent (you asked to regain access, link
  # valid for N minutes), and it carries the "if you did not request this,
  # ignore this email" line that a recovery mail needs. The wrong noun is the
  # cost. Fixing it properly means baking a custom template into the existing
  # overlay image (stacks/authentik/Dockerfile already exists for the two
  # runtime patches) and bumping the pinned tag — an auth-image rollout for an
  # email's wording, deliberately not bundled here.
  template = "email/password_reset.html"
}

# A dedicated stage rather than reusing signup-passkey-setup. The two flows can
# legitimately want different settings later — recovery may want a laxer
# user_verification if people struggle on a new device — and sharing one object
# would make that change silently affect signup too.
resource "authentik_stage_authenticator_webauthn" "recovery_passkey" {
  name                     = "recovery-passkey-setup"
  user_verification        = "required"
  resident_key_requirement = "required"
  # configure_flow unset: the stage runs INLINE in this flow rather than
  # sending the user off to a separate configuration flow.
}

resource "authentik_flow" "recovery" {
  # depends_on is the structural fix for what went wrong on 2026-09-02. The
  # first apply failed while creating the email stage, but terraform had already
  # created the flow and three of its four bindings — leaving a LIVE recovery
  # flow that ran identification -> register a passkey -> log in, with no email
  # proof at all. Anyone who knew a non-superuser's address could have taken
  # over that account. It existed for 3m41s; nobody reached it (one request to
  # the URL, from our own devvm) and no WebAuthn credential was created.
  #
  # Terraform cannot apply this atomically, so the flow must be the LAST thing
  # created. With every stage listed here, a stage failure means the flow is
  # never created either, and the bindings depend on the flow — so a partial
  # apply leaves unreferenced stage objects, which grant nothing, instead of a
  # reachable half-built flow. A flow is reachable at its slug URL whether or
  # not anything links to it, so "not wired up yet" is NOT a safety property.
  depends_on = [
    authentik_stage_identification.recovery_identification,
    authentik_stage_email.recovery_email,
    authentik_stage_authenticator_webauthn.recovery_passkey,
    data.authentik_stage.default_authentication_login,
  ]

  name           = "recovery"
  slug           = "recovery"
  title          = "Recover your access"
  designation    = "recovery"
  authentication = "require_unauthenticated"
}

resource "authentik_flow_stage_binding" "recovery_identification" {
  target = authentik_flow.recovery.uuid
  stage  = authentik_stage_identification.recovery_identification.id
  order  = 10
  # re_evaluate_policies keeps the superuser deny below effective on the
  # execution pass, once the identification stage has resolved a pending user —
  # on the plan pass there is no user to judge yet.
  evaluate_on_plan     = true
  re_evaluate_policies = true
}

resource "authentik_flow_stage_binding" "recovery_email" {
  target               = authentik_flow.recovery.uuid
  stage                = authentik_stage_email.recovery_email.id
  order                = 20
  evaluate_on_plan     = true
  re_evaluate_policies = true
}

# After the email token, before login: the credential row is a foreign key to a
# user, and the pending user is resolved by then.
resource "authentik_flow_stage_binding" "recovery_passkey" {
  target               = authentik_flow.recovery.uuid
  stage                = authentik_stage_authenticator_webauthn.recovery_passkey.id
  order                = 30
  evaluate_on_plan     = true
  re_evaluate_policies = false
}

resource "authentik_flow_stage_binding" "recovery_login" {
  target               = authentik_flow.recovery.uuid
  stage                = data.authentik_stage.default_authentication_login.id
  order                = 40
  evaluate_on_plan     = false
  re_evaluate_policies = true
}

data "authentik_stage" "default_authentication_login" {
  name = "default-authentication-login"
}

# Refuse recovery for a superuser. See the header for why this is the control
# that makes the flow safe to publish at all.
resource "authentik_policy_expression" "deny_superuser_recovery" {
  name = "deny-superuser-recovery"
  # get_pending_user() is the account the identification stage resolved. It
  # falls back to the request user, so the is_authenticated guard stops an
  # anonymous request being judged on a user that was never identified.
  expression = <<-EOT
    user = request.context.get("pending_user")
    if user is None:
      return True
    if not getattr(user, "is_authenticated", False):
      return True
    if getattr(user, "is_superuser", False):
      ak_message("Account recovery is not available for this account. Ask the administrator.")
      return False
    return True
  EOT
}

resource "authentik_policy_binding" "deny_superuser_on_recovery" {
  target = authentik_flow.recovery.uuid
  policy = authentik_policy_expression.deny_superuser_recovery.id
  order  = 0
  # A policy failure denies the flow rather than being treated as a pass.
  failure_result = false
  enabled        = true
}
