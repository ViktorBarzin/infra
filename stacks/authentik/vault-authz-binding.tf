# Vault OIDC authorization fence (ADR-0020). The "Vault" Authentik application had
# NO authorization binding (audit 2026-06-15: any authenticated identity could
# complete Vault OIDC login and receive Vault's built-in `default`-policy token —
# token self-management/cubbyhole, no secret access, but still more than an
# outside user should hold). Bind it to "Allow Login Users" so only established
# homelab users can log in: they inherit that base group via its children
# (Home Server Admins / Headscale Users / Wrongmove Users — verified live that
# `User.all_groups()` includes the parent), while publicly self-enrolled
# "TripIt External" users (deliberately PARENTLESS, so NOT in Allow Login Users)
# are denied at the Vault consent step. Closes the one OIDC app the forward-auth
# fence cannot reach; the other sensitive OIDC apps already bind a trusted group.
#
# The Vault application itself stays UI-managed (like the other OIDC apps); this
# adds ONLY the authorization binding. policy_engine_mode on the app is "any", so
# one group binding == membership in that group is required to authorize.
data "authentik_application" "vault" {
  slug = "vault"
}

data "authentik_group" "allow_login_users" {
  name = "Allow Login Users"
}

resource "authentik_policy_binding" "vault_allow_login_users" {
  target = data.authentik_application.vault.uuid
  group  = data.authentik_group.allow_login_users.id
  order  = 0
}
