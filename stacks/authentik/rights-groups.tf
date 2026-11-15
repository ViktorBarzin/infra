# Rights groups (enforced-identity plan, docs/plans/2026-11-15-enforced-identity-design.md,
# step 7). One list says who holds which right: Vault secret/platform k8s_users,
# projected here into Authentik groups. Kubernetes binds the groups
# (stacks/rbac, oidc-group-bindings.tf), Vault maps vault-admins to vault-admin
# (stacks/vault), and agent sessions arrive with the same groups under the
# `agent:` prefix. None of these groups is superuser, so an agent carrying them
# is never an Authentik admin.
#
# Until 2026-11-15 the three kubernetes-* groups existed but were filled by
# hand (kubernetes-admins held only akadmin), every right was also a binding
# per email, and Vault admin came from "authentik Admins", a superuser group.

locals {
  rights_users = jsondecode(nonsensitive(data.vault_kv_secret_v2.cf_platform.data["k8s_users"]))
  rights_emails = {
    for role in ["admin", "power-user", "namespace-owner"] :
    role => sort([for name, u in local.rights_users : u.email if u.role == role])
  }
  # Namespace -> the emails of its owners. novelapp is created by its own
  # stack rather than through k8s_users, so its owner is listed here.
  rights_namespace_owners = merge({
    for ns in distinct(flatten([for name, u in local.rights_users : coalesce(u.namespaces, []) if u.role == "namespace-owner"])) :
    ns => sort([for name, u in local.rights_users : u.email if u.role == "namespace-owner" && contains(coalesce(u.namespaces, []), ns)])
  }, { novelapp = ["vabbit81@gmail.com"] })
}

data "authentik_user" "rights" {
  for_each = toset(concat(flatten(values(local.rights_emails)), flatten(values(local.rights_namespace_owners))))
  username = each.value
}

# akadmin is Authentik's own break-glass admin and stays a cluster admin.
data "authentik_user" "akadmin" {
  username = "akadmin"
}

import {
  id = "e4b39bac-540f-49b1-a53d-697baf8c92c5"
  to = authentik_group.kubernetes_admins
}
import {
  id = "e5a6a70b-280e-40f0-a388-c0d5665e928d"
  to = authentik_group.kubernetes_power_users
}
import {
  id = "38552084-ee3e-412a-997e-d75bd83db352"
  to = authentik_group.kubernetes_namespace_owners
}

resource "authentik_group" "kubernetes_admins" {
  name = "kubernetes-admins"
  users = concat(
    [data.authentik_user.akadmin.id],
    [for e in local.rights_emails["admin"] : data.authentik_user.rights[e].id],
  )
}

resource "authentik_group" "kubernetes_power_users" {
  name  = "kubernetes-power-users"
  users = [for e in local.rights_emails["power-user"] : data.authentik_user.rights[e].id]
}

# Read-only across the cluster, like the per-email binding it replaces.
resource "authentik_group" "kubernetes_namespace_owners" {
  name  = "kubernetes-namespace-owners"
  users = [for e in local.rights_emails["namespace-owner"] : data.authentik_user.rights[e].id]
}

# admin inside one namespace (stacks/rbac binds the ClusterRole admin there).
resource "authentik_group" "kubernetes_namespace_owner" {
  for_each = local.rights_namespace_owners
  name     = "kubernetes-namespace-owner-${each.key}"
  users    = [for e in each.value : data.authentik_user.rights[e].id]
}

# Vault admin (stacks/vault maps it to the vault-admin policy).
resource "authentik_group" "vault_admins" {
  name  = "vault-admins"
  users = [for e in local.rights_emails["admin"] : data.authentik_user.rights[e].id]
}
