# Cloud's reconciler in Authentik (Cloud v1 plan in the cloud repo: "How does a
# private App check sign-in?"). Each private App gets its own OAuth2 provider,
# application and cloud-* group, created by the reconciler inside that
# Project's state. Those objects belong to Cloud's database, not this repo
# (AGENTS.md, "Cloud-owned objects"). This file gives the reconciler an
# identity and an RBAC role, and nothing else.
#
# The role, as granted:
#   global   create OAuth2 providers, applications, groups and policy
#            bindings; read users (to put a User in an App's group), flows,
#            certificate key pairs and scope mappings (to configure a
#            provider). No user changes, no flows, stages, outposts, sources,
#            tokens, roles or system settings.
#   own      view, change and delete only the objects it created, plus adding
#            and removing members of its own groups. Authentik grants these
#            through initial permissions: when a member of this role creates
#            an object, the role gets the listed permissions on that object
#            alone.
#
# WHAT AUTHENTIK RBAC CANNOT LIMIT (checked against authentik 2026.8.5, the
# live server, in authentik/core/api/groups.py and
# authentik/policies/api/bindings.py):
#   1. Group names. add_group lets the reconciler create a group with any
#      unused name; "cloud-*" is the reconciler's convention, not a rule.
#   2. Policy binding targets. add_policybinding does not check any permission
#      on the target, so the reconciler can bind one of its groups to an
#      application or flow it does not own, for example to grant a cloud-*
#      group access to an admin application whose bindings use mode "any".
#   3. Group parents. Members of a child group are members of its parents.
#      Authentik requires enable_group_superuser only for a parent that grants
#      superuser, so the reconciler can make a cloud-* group a child of
#      "Home Server Admins" (the forward-auth break-glass) and add a User.
# A stolen reconciler token could therefore reach homelab admin applications.
# The narrower alternative drops add_group and add_policybinding: each App's
# oauth2-proxy then admits an email allowlist the reconciler renders from
# Cloud's database, and the reconciler needs only providers and applications.
# That changes the Cloud v1 plan, so it is Viktor's decision.

locals {
  cloud_reconciler_global_permissions = [
    "authentik_providers_oauth2.add_oauth2provider",
    "authentik_core.add_application",
    "authentik_core.add_group",
    "authentik_policies.add_policybinding",
    "authentik_core.view_user",
    "authentik_flows.view_flow",
    "authentik_crypto.view_certificatekeypair",
    "authentik_providers_oauth2.view_scopemapping",
  ]

  # Granted on each object the reconciler creates, for that object only.
  # Codenames are unique among authentik's own permissions (checked against
  # /api/v3/rbac/permissions/ on 2026-11-13).
  cloud_reconciler_initial_permissions = [
    "view_oauth2provider", "change_oauth2provider", "delete_oauth2provider",
    "view_application", "change_application", "delete_application",
    "view_group", "change_group", "delete_group", "add_user_to_group", "remove_user_from_group",
    "view_policybinding", "change_policybinding", "delete_policybinding",
  ]
}

resource "authentik_rbac_role" "cloud_reconciler" {
  name = "cloud reconciler"
}

resource "authentik_rbac_permission_role" "cloud_reconciler" {
  for_each   = toset(local.cloud_reconciler_global_permissions)
  role       = authentik_rbac_role.cloud_reconciler.id
  permission = each.key
}

data "authentik_rbac_permission" "cloud_reconciler_initial" {
  for_each = toset(local.cloud_reconciler_initial_permissions)
  codename = each.key
}

resource "authentik_rbac_initial_permissions" "cloud_reconciler" {
  name        = "cloud reconciler: its own objects"
  role        = authentik_rbac_role.cloud_reconciler.id
  permissions = [for c in local.cloud_reconciler_initial_permissions : tonumber(data.authentik_rbac_permission.cloud_reconciler_initial[c].id)]
}

resource "authentik_group" "cloud_reconcilers" {
  name  = "cloud reconcilers"
  roles = [authentik_rbac_role.cloud_reconciler.id]
  # Holds only the service account below, which the user resource adds.
  lifecycle {
    ignore_changes = [users]
  }
}

resource "authentik_user" "cloud_reconciler" {
  username = "svc-cloud-reconciler"
  name     = "Cloud reconciler"
  type     = "service_account"
  path     = "goauthentik.io/service-accounts"
  groups   = [authentik_group.cloud_reconcilers.id]

  attributes = jsonencode({
    managed_by = "infra/stacks/authentik/cloud-reconciler.tf"
    purpose    = "Cloud's reconciler creates each private App's OAuth2 provider, application and cloud-* group"
  })
}

resource "authentik_token" "cloud_reconciler" {
  identifier   = "svc-cloud-reconciler"
  user         = authentik_user.cloud_reconciler.id
  intent       = "api"
  retrieve_key = true
  # Non-expiring, like the other service-account tokens here. Rotate by
  # tainting this resource; the apply rewrites secret/cloud/system.
  expiring    = false
  description = "Cloud reconciler API token. Rotate by tainting this resource."
}

# The reconciler reads its credentials from secret/cloud/system (read-only for
# it, stacks/vault cloud_policies.tf). Terraform is the only writer of this
# secret, so a rewrite here never drops a key someone added by hand:
#   authentik_token  the token above.
#   ghcr_pull_token  a read:packages-only GitHub token for pulling Project
#                    images. It does not exist yet and must never be the admin
#                    PAT. Viktor mints it in the GitHub UI and stores it as
#                    `vault kv patch secret/viktor cloud_ghcr_pull_token=<token>`;
#                    the next apply of this stack copies it here. Empty until
#                    then, and the reconciler treats empty as "not set".
# CI writes this path through its own policy grant (stacks/vault, policy ci),
# so stacks/vault must be applied before this file's first CI apply.
data "vault_kv_secret_v2" "viktor_cloud" {
  mount = "secret"
  name  = "viktor"
}

resource "vault_kv_secret_v2" "cloud_system" {
  mount = "secret"
  name  = "cloud/system"
  data_json = jsonencode({
    authentik_token = authentik_token.cloud_reconciler.key
    ghcr_pull_token = lookup(data.vault_kv_secret_v2.viktor_cloud.data, "cloud_ghcr_pull_token", "")
  })
}
