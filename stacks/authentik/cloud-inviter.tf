# Guest invite codes for Cloud's private Apps (cloud repo
# docs/plans/2026-11-14-cloud-app-kit.md, step K5, "How it works"; Viktor's
# choice: Cloud mints guarded codes rather than Viktor by hand).
#
# A Cloud owner invites an email to a private App. Cloud adds the email to the
# App's allow list and asks Authentik, as the service account below, for a
# single-use invite code. The guest makes an account through signup-start
# (social sign-up) or signup-passkey, types the code, and lands in
# "Cloud App Guests" and nothing else. Someone who already has an account
# needs no code: the allow list alone lets them in.
#
# This is the one exception to "Cloud creates nothing in Authentik"
# (AGENTS.md, "Cloud-owned objects"): Cloud creates Invitations, as
# cloud-inviter, and nothing else.
#
# The same account onboards a Cloud User in one Operator step (cloud repo
# B14, POST /api/v1/users, `cloud users add`): it puts an existing account in
# Cloud Users, and, when the Operator vouches for the email, in Cloud Email
# Vouched (cloud-apps.tf). Its role holds, besides add_invitation:
#   - view_user, global: add_user finds the account through the caller's
#     view_user (core/api/groups.py), and any account may be onboarded. The
#     console's membership reader holds the same global read already.
#   - add_user_to_group and view_group on exactly two groups, Cloud Users and
#     Cloud Email Vouched, as object permissions (the same shape as the
#     sign-up approvers', modules/authentik/app_signup).
# It holds no change_user, so it cannot edit a user, set an attribute or a
# password, and no permission on any other group: not Cloud Operators, not
# Home Server Admins. Cloud Operators' members are declared in stacks/cloud
# (admin_user_pks), so Operators stay a Terraform change.
#
# What keeps a stolen token from doing more than intended:
#   - It can read every account (as the reader token can), add any account
#     to Cloud Users (as the sign-up approver can), and vouch for any
#     account's email. A vouch admits an account whose email nothing
#     verified: today only accounts an admin made by hand. proxy_only
#     accounts stay refused whatever vouches for them.
#   - Authentik's API lets an Invitation carry any fixed_data, group and flow.
#     So validate-invite-code (invite-flow.tf), the gate of every code-based
#     sign-up, accepts a cloud-inviter invitation only when its fixed_data
#     keys are exactly code and target_group, the group is Cloud App Guests,
#     it is single use, and it expires within 7 days.
#   - An InvitationStage merges fixed_data into the new account's prompt data
#     (attributes.* keys included) and takes the email without checking it.
#     A deny stage right after the InvitationStage of every flow that has one
#     refuses any cloud-inviter invitation there (below).
#   - Cloud App Guests has no roles, no parent and no superuser flag, and no
#     application binds it. Guests reach Cloud Apps through cloud-apps, whose
#     policy admits vouched accounts (cloud-apps.tf), and a private App's
#     oauth2-proxy admits only the emails on its list.
#
# The token goes to Vault secret/cloud/inviter (key `token`), outside
# secret/cloud/system, which every Project's OpenTofu state reads, and outside
# every p-* tree. Cloud's console reads it through its own ExternalSecret
# (stacks/cloud console.tf); the reconciler's Vault policy does not reach it.
# CI writes it through its policy grant (stacks/vault main.tf, policy ci), so
# stacks/vault applies before this file's first CI apply.
#
# Rotate: taint authentik_token.cloud_inviter and apply; the ExternalSecret
# picks the new value up within its refresh interval and Reloader restarts the
# console. Revoke every outstanding code: docs/runbooks/cloud.md, "Guest
# invites".

locals {
  cloud_inviter_username = "cloud-inviter"
  cloud_guest_group_name = "Cloud App Guests"
  # Longest a cloud-inviter code may still have to run when it is used. Cloud
  # sets 7 days; the 10 minutes cover clock skew between Cloud and Authentik.
  cloud_invite_max_days = 7
}

resource "authentik_group" "cloud_app_guests" {
  name         = local.cloud_guest_group_name
  is_superuser = false
  attributes = jsonencode({
    managed_by = "infra/stacks/authentik/cloud-inviter.tf"
    purpose    = "Accounts made with a Cloud guest invite code. Grants nothing: a private Cloud App admits its guests by email."
  })
  # Members join at sign-up (assign-invite-group); Terraform does not own them.
  lifecycle {
    ignore_changes = [users]
  }
}

resource "authentik_rbac_role" "cloud_inviter" {
  name = "cloud inviter"
}

# Global, not object-scoped: an Invitation does not exist before it is made.
resource "authentik_rbac_permission_role" "cloud_inviter_add_invitation" {
  role       = authentik_rbac_role.cloud_inviter.id
  permission = "authentik_stages_invitation.add_invitation"
}

# Onboarding (above). Global: the account to onboard may be anyone's.
resource "authentik_rbac_permission_role" "cloud_inviter_view_user" {
  role       = authentik_rbac_role.cloud_inviter.id
  permission = "authentik_core.view_user"
}

# Cloud Users belongs to stacks/cloud (module.console, modules/authentik/
# app_signup); it exists before this stack's apply.
data "authentik_group" "cloud_users" {
  name          = "Cloud Users"
  include_users = false
}

locals {
  # The only groups cloud-inviter may add accounts to.
  cloud_inviter_onboard_groups = {
    cloud_users         = data.authentik_group.cloud_users.id
    cloud_email_vouched = authentik_group.cloud_email_vouched.id
  }
}

resource "authentik_rbac_permission_role" "cloud_inviter_add_to_group" {
  for_each   = local.cloud_inviter_onboard_groups
  role       = authentik_rbac_role.cloud_inviter.id
  permission = "authentik_core.add_user_to_group"
  model      = "authentik_core.group"
  object_id  = each.value
}

# Cloud finds each group's pk by name (GET /core/groups/?name=).
resource "authentik_rbac_permission_role" "cloud_inviter_view_group" {
  for_each   = local.cloud_inviter_onboard_groups
  role       = authentik_rbac_role.cloud_inviter.id
  permission = "authentik_core.view_group"
  model      = "authentik_core.group"
  object_id  = each.value
}

resource "authentik_group" "cloud_inviters" {
  name  = "cloud inviters"
  roles = [authentik_rbac_role.cloud_inviter.id]
  # Holds only the service account below, which the user resource adds.
  lifecycle {
    ignore_changes = [users]
  }
}

resource "authentik_user" "cloud_inviter" {
  username = local.cloud_inviter_username
  name     = "Cloud (guest invites, onboarding)"
  type     = "service_account"
  path     = "goauthentik.io/service-accounts"
  groups   = [authentik_group.cloud_inviters.id]

  attributes = jsonencode({
    managed_by = "infra/stacks/authentik/cloud-inviter.tf"
    purpose    = "Cloud's console creates single-use guest invite codes for Cloud App Guests, and adds accounts to Cloud Users and Cloud Email Vouched"
  })
}

resource "authentik_token" "cloud_inviter" {
  identifier   = local.cloud_inviter_username
  user         = authentik_user.cloud_inviter.id
  intent       = "api"
  retrieve_key = true
  # Non-expiring, like the sign-up approvers' tokens (modules/authentik/
  # app_signup): a token that lapses on a date nobody watches turns invites
  # into silent failures. Rotate by tainting this resource.
  expiring    = false
  description = "Cloud's guest invite codes and onboarding. Rotate by tainting this resource."
}

resource "vault_kv_secret_v2" "cloud_inviter" {
  mount = "secret"
  name  = "cloud/inviter"
  data_json = jsonencode({
    token = authentik_token.cloud_inviter.key
  })
}

# --- Refuse cloud-inviter invitations on InvitationStage flows ---------------
#
# A policy bound to the flow cannot do this: it is evaluated when the flow is
# entered, before the InvitationStage has read the invitation (the reason
# recovery-flow.tf uses a deny stage too), and Authentik caches its result for
# a signed-in session. So a deny stage sits right after each InvitationStage,
# kept in the plan (evaluate_on_plan false) and judged when it is reached,
# when the plan context holds the invitation in effect.
#
# Every flow with an InvitationStage, by slug, with the order just after that
# stage. invitation-enrollment's InvitationStage is at order 10
# (.claude/reference/authentik-state.md). It is the only one this repo or its
# docs know of; GET /api/v3/stages/invitation/stages/ lists each
# InvitationStage with its flows (docs/runbooks/cloud.md, "Guest invites").
locals {
  cloud_invitation_stage_flows = {
    "invitation-enrollment" = 11
  }
}

data "authentik_flow" "invitation_stage_flows" {
  for_each = local.cloud_invitation_stage_flows
  slug     = each.key
}

resource "authentik_stage_deny" "cloud_guest_invite" {
  name         = "deny-cloud-guest-invite"
  deny_message = "This invitation does not work here. Open the sign-up link from your invitation and enter the code."
}

# True for exactly the invitations that must be stopped: those cloud-inviter
# created. No invitation in effect means nothing to stop.
resource "authentik_policy_expression" "cloud_inviter_invitation" {
  name       = "invitation-made-by-cloud-inviter"
  expression = <<-EOT
    CLOUD_INVITER_PK = int("${authentik_user.cloud_inviter.id}")
    invitation = request.context.get("invitation")
    if invitation is None:
        return False
    return getattr(invitation, "created_by_id", None) == CLOUD_INVITER_PK
  EOT
}

resource "authentik_flow_stage_binding" "cloud_guest_invite_deny" {
  for_each = local.cloud_invitation_stage_flows
  target   = data.authentik_flow.invitation_stage_flows[each.key].id
  stage    = authentik_stage_deny.cloud_guest_invite.id
  order    = each.value
  # evaluate_on_plan MUST be false: at plan time no invitation is in effect,
  # so the policy would drop the stage from the plan for good.
  evaluate_on_plan     = false
  re_evaluate_policies = true
}

resource "authentik_policy_binding" "cloud_guest_invite_deny" {
  for_each = local.cloud_invitation_stage_flows
  target   = authentik_flow_stage_binding.cloud_guest_invite_deny[each.key].id
  policy   = authentik_policy_expression.cloud_inviter_invitation.id
  order    = 0
  # A policy that errors includes the deny stage: fail closed.
  failure_result = true
  enabled        = true
}
