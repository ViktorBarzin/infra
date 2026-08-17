# "T3 Users" group — gates the devvm Claude Code Workstation (t3.viktorbarzin.me)
# at the Authentik edge (the branch in admin-services-restriction.tf). The group
# is created WITH its members atomically so enabling the gate can never lock
# everyone (incl. wizard) out.
#
# emo / wizard are NOT Terraform-managed authentik_user resources in this stack,
# so they're looked up by username — which in this Authentik instance IS the
# user's email (verified live 2026-06-08): vbarzin@gmail.com, etc.
#
# Membership is in HCL for now (matches the roster's users). FUTURE: when the
# devvm provisioner reconciles T3 Users membership from roster.yaml via the
# Authentik API, drop the `users` arg here so TF owns only the group's existence
# — which would also mean a roster removal revoked the group by itself, rather
# than needing the two edits that 2026-08-17 needed.

data "authentik_user" "wizard" {
  username = "vbarzin@gmail.com"
}

data "authentik_user" "emo" {
  username = "emil.barzin@gmail.com"
}

// ancamilea (ancaelena98@gmail.com) was removed from this group on 2026-08-17
// (Viktor). She had an account on the devvm but never used it: parked on
// 2026-08-16, and T3 Users was her only door to it — she is not in "Home Server
// Admins", so the web terminal was never reachable for her either. Her roster
// entry went with this change, so the reconcile has dropped her from
// /etc/ttyd-user-map and dispatch.json too. Her other app grants (Forgejo,
// TripIt, Postiz, Wrongmove, Headscale) are untouched. To bring her back:
// re-add the data lookup and the group member here, and un-comment her line in
// scripts/workstation/roster.yaml.

resource "authentik_group" "t3_users" {
  name = "T3 Users"
  users = [
    data.authentik_user.wizard.id,
    data.authentik_user.emo.id,
  ]
}
