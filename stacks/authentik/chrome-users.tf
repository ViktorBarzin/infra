# Chrome Users group (ADR-0023): replaces the former per-identity CHROME_ALLOWED
# list in admin-services-restriction. chrome.viktorbarzin.me / chrome-fleet expose
# LIVE logged-in browser sessions from the shared profile, so access is kept
# deliberately narrow — the chrome-service ingress binds allowed_groups =
# ["Chrome Users"] only.
#
# Starts EMPTY on purpose: the three historical chrome users (Viktor, emo, akadmin)
# are all in "Home Server Admins" and therefore already reach chrome via the
# break-glass admin bypass in admin-services-restriction. Add a NON-admin here (via
# the Authentik UI or a users= entry) only when someone who is not a Home Server
# Admin needs the shared browser. Access is group membership — nothing else.
resource "authentik_group" "chrome_users" {
  name = "Chrome Users"
}
