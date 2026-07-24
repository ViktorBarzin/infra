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
