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
