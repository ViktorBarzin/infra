# -----------------------------------------------------------------------------
# RBAC keyed on the OIDC `groups` claim, for humans and for agent sessions.
#
# WHY, alongside the per-email bindings in main.tf: those bindings are keyed on
# an email from the `k8s_users` map in Vault, and the two have drifted. Measured
# 2026-09-01 against live state:
#
#   * `oidc-admin-viktor` binds `viktor@viktorbarzin.me` to cluster-admin. No
#     Authentik user holds that email, so the binding matches nobody.
#   * `oidc-admin-vbarzin` (Viktor's real address) and `oidc-admin-akadmin` DO
#     work — and both were made with `kubectl create` (metadata.managedFields
#     manager `kubectl-create`, 2026-02-17), so neither is in Terraform state
#     and neither is described anywhere in this repo.
#
# A group-keyed binding removes the per-person bookkeeping: membership moves in
# Authentik, which is already where the identity lives, and the cluster side
# stops needing an edit per person. The per-email bindings stay as they are —
# retiring them is a separate change, and doing it in the same breath as
# enabling a new issuer would make a bad day hard to unpick.
#
# The claim carries Authentik group names verbatim (property mapping
# "Kubernetes Groups": `[group.name for group in request.user.ak_groups.all()]`)
# and the human issuers map groups with an empty prefix, so these map keys ARE
# the group names in Authentik.
#
# APPLYING THIS GRANTS NOBODY ANYTHING NEW. Checked against live membership and
# live bindings on 2026-09-01:
#   kubernetes-admins           = [akadmin]              already cluster-admin via oidc-admin-akadmin
#   kubernetes-power-users      = []                      empty
#   kubernetes-namespace-owners = [vabbit81@gmail.com]    already oidc-namespace-owner-readonly via oidc-ns-owner-readonly-vabbit81
# and every `agent:*` row matches nothing at all until a human enables the agent
# issuer (`agent_oidc_enabled`). Re-check membership before assuming this still
# holds; a new member of kubernetes-admins gets cluster-admin from here on.
# -----------------------------------------------------------------------------

locals {
  # Authentik group name (as it arrives in the `groups` claim) -> ClusterRole.
  oidc_group_cluster_roles = {
    # --- Humans. Same three roles as the per-email bindings in main.tf. ------
    "kubernetes-admins"           = "cluster-admin"
    "kubernetes-power-users"      = kubernetes_cluster_role.power_user_readonly.metadata[0].name
    "kubernetes-namespace-owners" = kubernetes_cluster_role.namespace_owner_readonly.metadata[0].name

    # --- Agent sessions. -----------------------------------------------------
    # The agent issuer prefixes groups with `agent:`, so these are separate
    # subjects from the three above and an agent inherits no human binding.
    #
    # Read-only on purpose, including for `agent:kubernetes-admins`. Two
    # reasons, not one: the org-wide workstation policy already says an agent's
    # kubectl is read-only and every infrastructure change goes through
    # Terraform, so write verbs here would authorise a path we tell agents not
    # to use; and an agent's refresh token is a standing credential in a token
    # cache, so this is the ceiling on what a leaked one is worth.
    # `oidc-power-user-readonly` grants cluster-wide get/list/watch and
    # explicitly no secrets and no pods/exec (ADR-0005).
    #
    # An agent that genuinely needs to write should get a purpose-scoped
    # binding of its own, named for the job, rather than a widening of this row.
    "agent:kubernetes-admins"           = kubernetes_cluster_role.power_user_readonly.metadata[0].name
    "agent:kubernetes-power-users"      = kubernetes_cluster_role.power_user_readonly.metadata[0].name
    "agent:kubernetes-namespace-owners" = kubernetes_cluster_role.namespace_owner_readonly.metadata[0].name
  }
}

resource "kubernetes_cluster_role_binding" "oidc_groups" {
  for_each = local.oidc_group_cluster_roles

  metadata {
    # `:` is not legal in a Kubernetes object name (DNS subdomain), so the
    # agent prefix becomes a dash in the binding name. The SUBJECT keeps the
    # colon, which is what has to match the claim.
    name = "oidc-group-${replace(each.key, ":", "-")}"

    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "viktorbarzin.me/identity"     = startswith(each.key, "agent:") ? "agent" : "human"
    }
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = each.value
  }

  subject {
    kind      = "Group"
    name      = each.key
    api_group = "rbac.authorization.k8s.io"
  }
}
