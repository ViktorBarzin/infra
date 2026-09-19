# The agent's own Authentik identity, for reaching apps behind forward-auth.
#
# WHY THIS EXISTS. Everything on this estate that matters sits behind the
# Authentik proxy outpost, and until now an agent had no way through it. The
# accounts in Vault do not help: vbarzin@gmail.com's password is correct but
# its only second factor is a WebAuthn passkey with no TOTP and no recovery
# code (checked live 2026-09-19 against default-authentication-flow, which
# answered ak-stage-authenticator-validate offering device_class webauthn and
# nothing else), me@viktorbarzin.me no longer authenticates, and emo's account
# is not ours to drive. A passkey cannot be replayed from a script, so an
# agent debugging f1-stream's /pair or waking the Android emulator was stuck
# asking a person to click.
#
# A service account is the supported answer. authentik's own documentation is
# explicit that user-created service accounts authenticate to FLOWS with an
# app password, while API tokens only reach /api/v3/ — and a service account
# carries no MFA stage, so the authentication flow completes with a username
# and a password alone. The session cookie that falls out is an ordinary
# Authentik session, so the outpost treats this account exactly as it treats a
# person. Nothing here forges a header or steps around the outpost, which is
# what f1-stream audit item 15 closed and what must stay closed.
#
# THE GRANT IS BROAD, DELIBERATELY, AND VIKTOR CHOSE IT (2026-09-19).
# "Home Server Admins" is the unconditional break-glass in
# admin-services-restriction.tf: it is evaluated before the per-host table and
# therefore reaches EVERY forward-auth host, chrome.viktorbarzin.me and its
# live signed-in browser sessions included. The narrower option was a new
# group added to the host table per host, and it was declined because
# f1-stream's /pair checks this exact group name (backend/admin.py:36), so the
# narrow group would have needed an f1-stream code change to widen the pairing
# gate — the wrong thing to widen. The trade recorded: one credential in Vault
# now carries admin reach, so treat its app password as an admin password.
#
# What it does NOT get: the group reads is_superuser=false (checked against
# /api/v3/core/groups/ on 2026-09-19, 3 members), so this account cannot
# administer authentik itself. Its reach is the forward-auth estate, not the
# identity provider.
#
# THE APP PASSWORD IS NOT IN THIS STATE BY DESIGN. The provider generates it
# and `retrieve_key` would put it in the plan output and in state. It is read
# once after apply from /api/v3/core/tokens/<identifier>/view_key/ with the
# existing tf_api_token and written to Vault, which is where the CLI reads it.

data "authentik_group" "home_server_admins" {
  name = "Home Server Admins"
}

resource "authentik_user" "agent" {
  username = "svc-agent"
  name     = "Agent (Claude Code)"
  email    = "svc-agent@viktorbarzin.me"
  type     = "service_account"
  path     = "goauthentik.io/service-accounts"
  groups   = [data.authentik_group.home_server_admins.id]

  attributes = jsonencode({
    # Read by nothing today. Here so whoever finds this account in the UI
    # knows what it is for and who to ask before deleting it.
    managed_by = "infra/stacks/authentik/agent-service-account.tf"
    purpose    = "agent access to apps behind Authentik forward-auth"
  })
}

resource "authentik_token" "agent_app_password" {
  identifier = "svc-agent-app-password"
  user       = authentik_user.agent.id
  intent     = "app_password"
  # Non-expiring, like the terraform-infra-stack token beside it. A password
  # that dies on a date nobody is watching turns into an outage during a race
  # weekend, and revoking is a one-line delete here when that is wanted.
  expiring    = false
  description = "Agent flow login. Rotate by tainting this resource."
}

# --- Letting the service account past the MFA stage ---------------------------
#
# default-authentication-flow binds default-authentication-mfa-validation at
# order 30 with not_configured_action=configure, so a user holding no
# authenticator is sent to enrol one rather than waved through. That is right
# for people and impossible for a service account: measured 2026-09-19, the
# flow answered ak-stage-authenticator-webauthn, the ENROLMENT stage, which
# needs a physical authenticator svc-agent will never have.
#
# The stage is skipped for this one account by name, and for nothing else.
#
# WHY A NAME AND NOT A TYPE. `user.type == "service_account"` reads better and
# is wrong here: it would wave through every service account this instance ever
# grows, including ones created by an app integration for their own reasons.
# A username is the narrowest thing that unblocks the account we just made, and
# a second agent account is one more line here, deliberately visible in a diff.
#
# WHY IT FAILS CLOSED. A policy bound to a stage skips that stage when it
# returns False. Every path through this expression that is not exactly
# svc-agent returns True, including the one where there is no pending user at
# all, so a broken context keeps MFA on rather than turning it off for the
# estate.
resource "authentik_policy_expression" "skip_mfa_for_agent" {
  name = "skip-mfa-for-agent-service-account"

  # Logged so the next person debugging this can read what the policy saw
  # rather than guessing at the flow context the way this one was written.
  execution_logging = true

  expression = <<-EOT
    # Skip the MFA stage for one thing: an app-password login by the agent's
    # own token. Everything else, and anything unrecognised, keeps MFA.
    #
    # KEYED ON THE TOKEN, not on the user. The obvious version compared
    # `pending_user.username`, and it did not work: measured 2026-09-19, that
    # key is empty where this stage is evaluated, so the expression took its
    # own fail-closed branch and the stage ran anyway. The password stage does
    # set `auth_method`, and an authentik app password authenticates as
    # `token`, so the credential itself is what this recognises.
    method = request.context.get("auth_method")
    args = request.context.get("auth_method_args") or {}
    ak_logger.info("skip-mfa-for-agent", method=method, args_keys=list(args.keys()))

    if method != "token":
        return True

    token = args.get("token") or {}
    identifier = token.get("identifier", "") if isinstance(token, dict) else getattr(token, "identifier", "")
    identifier = identifier or args.get("identifier", "")
    ak_logger.info("skip-mfa-for-agent token", identifier=identifier)
    return identifier != "${authentik_token.agent_app_password.identifier}"
  EOT
}

resource "authentik_policy_binding" "skip_mfa_for_agent" {
  # The order-30 stage binding of default-authentication-flow
  # (default-authentication-mfa-validation). A raw pk because the flow and its
  # bindings are authentik built-ins rather than resources in this stack, the
  # same shape app-access-bindings.tf uses for the TripIt app.
  target = "d471dda8-e258-453d-86d7-14963f87ec03"
  policy = authentik_policy_expression.skip_mfa_for_agent.id
  order  = 0
}
