# "Home Users": the household's door to the services behind Authentik that
# hold nothing sensitive. Created 2026-10-11 (ADR-0031).
#
# What the group reaches is decided per host, not here. A forward-auth host
# opts in by naming "Home Users" both in its ingress `allowed_groups` and in
# forward-auth-apps.json, which gives it its own forward_single provider
# (forward-auth-apps.tf). OIDC apps opt in with a policy binding. Everything
# else stays with Home Server Admins, so a new service is admin-only until
# someone adds it.
#
# This group replaced three single-purpose groups the same household was in:
# "Pages Readers" (pages.viktorbarzin.me), "TripIt Users" (the TripIt App) and
# "F1 Users" (stacks/f1-stream). Headscale Users and Wrongmove Users stay
# separate because they also hold people outside the household.
#
# Membership is declared here, and this list is authoritative: someone added
# in the Authentik UI is removed on the next apply. Removing a person is
# deleting a line AND revoking their sessions in the Authentik admin UI
# (Directory > Users > Sessions), because a forward_single session is only
# re-checked against the group when it expires, after up to 4 weeks.
# Usernames in this instance are email addresses.

data "authentik_user" "valia" {
  # "Валентина Колева-Барзина".
  username = "valentinakolevabarzina@gmail.com"
}

data "authentik_user" "anca" {
  # "Anca Milea". NOT anca.r.cristian10@gmail.com: that second account of hers
  # last logged in Jul 2025 and holds only Wrongmove.
  username = "ancaelena98@gmail.com"
}

data "authentik_user" "gheorghe" {
  # "GHEORGHE Milea", also a kubernetes namespace owner.
  username = "vabbit81@gmail.com"
}

resource "authentik_group" "home_users" {
  name = "Home Users"
  users = [
    data.authentik_user.valia.id,
    data.authentik_user.anca.id,
    data.authentik_user.gheorghe.id,
  ]
}

# --- OIDC apps --------------------------------------------------------------
#
# Immich and Linkwarden are UI-managed applications already bound to Home
# Server Admins at order 0 (also UI-managed). Both create a separate, empty
# account per OIDC user, so this grants a household member their own library,
# not Viktor's. pbm_uuid literals for the reason app-access-bindings.tf gives.

resource "authentik_policy_binding" "immich_home_users" {
  target = "d51932d3-2fbd-4d9f-ad94-8baaf3311f25" # app "Immich"
  group  = authentik_group.home_users.id
  order  = 1
}

resource "authentik_policy_binding" "linkwarden_home_users" {
  target = "85bca6c8-fd52-418f-96fe-bf263320ae88" # app "linkwarden"
  group  = authentik_group.home_users.id
  order  = 1
}
