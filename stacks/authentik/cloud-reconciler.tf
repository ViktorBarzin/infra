# Cloud's reconciler in Authentik (Cloud v1 plan in the cloud repo: "How does a
# private App check sign-in?"). This file gives the reconciler an identity and
# a deliberately narrow RBAC role. Any OAuth2 providers and applications it
# creates belong to Cloud's database, not this repo (AGENTS.md, "Cloud-owned
# objects").
#
# The role, as granted until Viktor picks the sign-in design below:
#   global   read users, flows, certificate key pairs and scope mappings. It
#            creates nothing: no providers, applications, groups or policy
#            bindings, no user changes, no flows, stages, outposts, sources,
#            tokens, roles or settings.
#   own      view, change and delete only the providers and applications it
#            created, through initial permissions: when a member of this role
#            creates an object, the role gets the listed permissions on that
#            object alone. Inert while the role cannot create; kept so that
#            option a below adds only the create grants.
#
# WHY NO GROUPS OR BINDINGS. The plan's design gives each private App its own
# cloud-* group and a policy binding. Authentik RBAC cannot box that in
# (authentik 2026.8.5, authentik/core/api/groups.py and
# authentik/policies/api/bindings.py):
#   1. add_group creates a group with any unused name; "cloud-*" would be a
#      convention, not a rule.
#   2. add_policybinding checks no permission on the target, so the role could
#      bind a group to any application or flow, including an admin
#      application under policy_engine_mode "any".
#   3. change_group on its own group can set any parent. Members of a child
#      are members of its parents, and Authentik guards only parents that
#      grant superuser, so a cloud-* group could become a child of "Home
#      Server Admins" (the forward-auth break-glass).
# A stolen token would then reach every homelab admin application. Until
# Viktor decides, the role holds neither grant.
#
# WHY NO PROVIDERS OR APPLICATIONS EITHER, FOR NOW. With
# core_default_app_access off (system-settings.tf), an application with no
# binding admits nobody, and app-access-guard.tf fails this stack's plan,
# apply and nightly drift plan for it. Without the binding grant, every
# application the role created would trip the guard, so it holds no create
# grant at all. Per-App sign-in needs one of these before M4, and the choice
# is Viktor's:
#   a. Accept the risk above: add authentik_providers_oauth2.add_oauth2provider,
#      authentik_core.add_application, authentik_core.add_group and
#      authentik_policies.add_policybinding (with view/change/delete and
#      membership initial permissions), record the acceptance in the cloud
#      repo's plan or an ADR, and extend app-access-guard.tf to fail on any
#      cloud-* group with a parent or with a binding on an application Cloud
#      did not create.
#   b. One OAuth2 provider and application owned by this repo, bound to group
#      Cloud Users, with a regex redirect URI for the App hosts. Each App's
#      oauth2-proxy admits an email allowlist the reconciler renders from
#      Cloud's database. The reconciler then needs no Authentik write access,
#      and this role can drop its read grants too.
#
# data.http.cloud_reconciler_permissions below reads the role back from the
# live API on every plan, including the nightly drift plan, and fails if its
# global or initial permissions differ from these lists.

locals {
  # app_label.codename, the form Authentik's global permissions take.
  cloud_reconciler_global_permissions = [
    "authentik_core.view_user",
    "authentik_flows.view_flow",
    "authentik_crypto.view_certificatekeypair",
    "authentik_providers_oauth2.view_scopemapping",
  ]

  # Granted on each object the reconciler creates, for that object only.
  # Codename => app label. The data source looks a permission up by codename
  # alone, so its postcondition checks the app label, which fails the plan if
  # a codename ever matches a permission in another app.
  cloud_reconciler_initial_permissions = {
    view_oauth2provider   = "authentik_providers_oauth2"
    change_oauth2provider = "authentik_providers_oauth2"
    delete_oauth2provider = "authentik_providers_oauth2"
    view_application      = "authentik_core"
    change_application    = "authentik_core"
    delete_application    = "authentik_core"
  }
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
  for_each = local.cloud_reconciler_initial_permissions
  codename = each.key

  lifecycle {
    postcondition {
      condition     = self.app == each.value
      error_message = "Authentik permission ${each.key} resolved to app ${self.app}, expected ${each.value}; the codename is not unique, so pick the permission by ID."
    }
  }
}

resource "authentik_rbac_initial_permissions" "cloud_reconciler" {
  name        = "cloud reconciler: its own objects"
  role        = authentik_rbac_role.cloud_reconciler.id
  permissions = [for c in sort(keys(local.cloud_reconciler_initial_permissions)) : tonumber(data.authentik_rbac_permission.cloud_reconciler_initial[c].id)]
}

# Live read-back of the role. Runs on every plan of this stack and in the
# nightly drift plan, so a permission added in the UI or by a provider bug
# fails the plan. 100 rows is far above the 4 global permissions it may hold.
data "http" "cloud_reconciler_permissions" {
  url             = "${local.authentik_api}/rbac/permissions/?role=${authentik_rbac_role.cloud_reconciler.id}&ordering=codename&page_size=100"
  request_headers = local.authentik_api_headers
  depends_on      = [authentik_rbac_permission_role.cloud_reconciler]

  lifecycle {
    postcondition {
      condition     = try(sort([for p in jsondecode(self.response_body).results : "${p.app_label}.${p.codename}"]) == sort(local.cloud_reconciler_global_permissions), false)
      error_message = "Authentik role \"cloud reconciler\" does not hold exactly local.cloud_reconciler_global_permissions (HTTP ${self.status_code}). Live: ${try(join(", ", [for p in jsondecode(self.response_body).results : "${p.app_label}.${p.codename}"]), "unreadable")}. Remove the extra permission in Authentik, or change the list in stacks/authentik/cloud-reconciler.tf."
    }
  }
}

data "http" "cloud_reconciler_initial_permissions" {
  url             = "${local.authentik_api}/rbac/initial_permissions/${authentik_rbac_initial_permissions.cloud_reconciler.id}/"
  request_headers = local.authentik_api_headers

  lifecycle {
    postcondition {
      condition     = try(jsondecode(self.response_body).role == authentik_rbac_role.cloud_reconciler.id && sort([for p in jsondecode(self.response_body).permissions_obj : "${p.app_label}.${p.codename}"]) == sort([for c, app in local.cloud_reconciler_initial_permissions : "${app}.${c}"]), false)
      error_message = "Authentik initial permissions \"cloud reconciler: its own objects\" differ from local.cloud_reconciler_initial_permissions (HTTP ${self.status_code}). Fix them in Authentik or in stacks/authentik/cloud-reconciler.tf."
    }
  }
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
    purpose    = "Cloud's reconciler; Authentik rights wait on the sign-in design in stacks/authentik/cloud-reconciler.tf"
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
