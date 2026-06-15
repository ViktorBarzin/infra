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
#
# UUIDs are PINNED as literals: this provider version has NO
# `data "authentik_application"` data source (CI pipeline 198 failed on it), and
# both objects are UI-managed and stable. To re-fetch if either is recreated, run
# `ak shell` in the goauthentik-server pod and read
# `Application.objects.get(name="Vault").pbm_uuid` and
# `Group.objects.get(name="Allow Login Users").group_uuid`.
resource "authentik_policy_binding" "vault_allow_login_users" {
  target = "fe5698e3-b6b1-4475-98fa-ce2bae22f4dd" # Authentik application "Vault" (pbm_uuid)
  group  = "b4823cd7-8ed8-4d2f-8f94-bc285138f853" # group "Allow Login Users" (group_uuid)
  order  = 0
}
