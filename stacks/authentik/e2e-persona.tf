# The e2e persona: a throwaway Cloud User that Viktor's agents test Cloud as
# (cloud repo docs/build/render-parity/checklist-and-backlog.md, item B00,
# "E2e persona: emo or a fresh account"; Viktor chose a fresh account on
# 2026-11-15). The parity gates create and delete about 60 Projects per
# batch, crash-loop Apps and fill databases, so they run here and not on a
# real person's account.
#
# Rights: emo's, minus everything personal or infra-wide. emo is in Home
# Server Admins (break-glass to every forward-auth host), Headscale Users
# (his VPN devices), T3 Users (his devvm workstation; membership there makes
# t3-membership-sync write a roster row), kubernetes-power-users (cluster
# read), Agent impersonatable and Cloud Users. The persona gets only the last
# two, because its acceptance tests forbid kubectl and infra access:
#   - Agent impersonatable, below in agent-service-account.tf, so an agent
#     signs in as it with `homelab browser ... --as persona`;
#   - Cloud Users and the email vouch ("Cloud Email Vouched") come from
#     Cloud's Operator action `cloud users add persona --vouch <email>`, which tests
#     that action. Terraform must not set either.
#
# No password and no authenticator: nobody signs in as the persona except by
# impersonation, which writes an impersonation_started event with a reason.
#
# The email is on our domain. Until the mailserver has a persona@ mailbox
# (B04, Batch 2), mail to it falls to the domain catch-all.
#
# Its Forgejo account `persona` and that account's token are runtime data in
# Vault secret/cloud/persona (docs/runbooks/cloud.md, "E2e persona").
#
# Rollback: set is_active = false and apply. That stops impersonation and
# every sign-in at once; the Projects stay until an Operator deletes them.
resource "authentik_user" "persona" {
  username = "persona"
  name     = "Cloud e2e persona"
  email    = "persona@viktorbarzin.me"
  type     = "internal"
  path     = "users"

  attributes = jsonencode({
    managed_by = "infra/stacks/authentik/e2e-persona.tf"
    purpose    = "test account for Cloud's end-to-end tests; not a person"
  })

  # Cloud's Operator action adds Cloud Users and Cloud Email Vouched at run
  # time through /core/groups/<pk>/add_user/. `groups` is computed when it is
  # not set, so a plan shows no diff today; the ignore keeps a later edit of
  # this resource from sending a stale group list in its PUT.
  lifecycle {
    ignore_changes = [groups]
  }
}
