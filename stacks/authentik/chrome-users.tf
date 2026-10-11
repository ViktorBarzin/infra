# Chrome Users group (ADR-0023; enforced per host since ADR-0031 through
# forward-auth-apps.json). chrome.viktorbarzin.me / chrome-fleet expose
# LIVE logged-in browser sessions from the shared profile, so access is kept
# deliberately narrow — the chrome-service ingress binds allowed_groups =
# ["Chrome Users"] only.
#
# Starts EMPTY on purpose: the three historical chrome users (Viktor, emo, akadmin)
# are all in "Home Server Admins", which is bound on every per-host application
# (forward-auth-apps.tf). Add a NON-admin here (via
# the Authentik UI or a users= entry) only when someone who is not a Home Server
# Admin needs the shared browser. Access is group membership — nothing else.
resource "authentik_group" "chrome_users" {
  name = "Chrome Users"
}
