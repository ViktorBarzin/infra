# "T3 Users" group — gates the devvm Claude Code Workstation (t3.viktorbarzin.me)
# at the Authentik edge (the branch in admin-services-restriction.tf). The group
# is created WITH its members atomically so enabling the gate can never lock
# everyone (incl. wizard) out.
#
# emo / ancamilea / wizard are NOT Terraform-managed authentik_user resources in
# this stack, so they're looked up by username — which in this Authentik instance
# IS the user's email (verified live 2026-06-08): vbarzin@gmail.com, etc.
#
# Membership is in HCL for now (matches the roster's 3 users). FUTURE: when the
# devvm provisioner reconciles T3 Users membership from roster.yaml via the
# Authentik API, drop the `users` arg here so TF owns only the group's existence.

data "authentik_user" "wizard" {
  username = "vbarzin@gmail.com"
}

data "authentik_user" "emo" {
  username = "emil.barzin@gmail.com"
}

data "authentik_user" "ancamilea" {
  username = "ancaelena98@gmail.com"
}

resource "authentik_group" "t3_users" {
  name = "T3 Users"
  users = [
    data.authentik_user.wizard.id,
    data.authentik_user.emo.id,
    data.authentik_user.ancamilea.id,
  ]
}
