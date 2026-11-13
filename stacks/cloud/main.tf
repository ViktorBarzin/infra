# Cloud: the homelab's self-hosted cloud (code: Forgejo viktor/cloud; plan
# docs/plans/2026-11-12-cloud-v1-and-operator.md and ADR-0003 there).
#
# This stack holds the Kubernetes identity and limits of Cloud's reconciler.
# What the reconciler may do is in access_rules.tf (tested by
# tests/cloud-access.test.sh; the Calico tier and floors also by
# tests/cloud-calico.test.sh). Cloud's Postgres roles are in stacks/dbaas
# (cloud_postgres.tf), its Vault roles in stacks/vault (cloud.tf), and the
# shared Authentik client for private Apps in stacks/authentik (cloud-apps.tf).
# Milestone M4 adds the console (console.tf, one tanstack_app call), the
# reconciler Deployment (reconciler.tf), the CLI's sign-in client
# (cli_sign_in.tf); what they read is in deploy_rules.tf (tested by
# tests/cloud-deploy.test.sh). docs/architecture/cloud.md describes the whole.
#
# Scope: Project namespaces (p-*) and everything in them, the Project roles and
# databases on the shared CNPG cluster and secret/cloud/<namespace>/* belong
# to Cloud's database, not this repo (AGENTS.md, "Cloud-owned objects").

# The namespace `cloud` is the console module's (console.tf) since M4. M2
# created it here with the module's labels and lifecycle, so the move plans
# zero changes.
moved {
  from = kubernetes_namespace.cloud
  to   = module.console.kubernetes_namespace.this
}

# The reconciler talks to the API server, Vault (Kubernetes auth role
# cloud-reconciler) and Postgres with this identity.
resource "kubernetes_service_account" "cloud_reconciler" {
  metadata {
    name      = local.cloud_reconciler_sa
    namespace = module.console.namespace
  }
}

# The console's service account is the module's since M4 (console.tf). M2 made
# it without a token; M4 mounts one for TakenHosts, so the move updates it in
# place.
moved {
  from = kubernetes_service_account.cloud_console
  to   = module.console.kubernetes_service_account.this[0]
}

resource "kubernetes_cluster_role" "cloud_reconciler" {
  metadata { name = "cloud-reconciler" }
  dynamic "rule" {
    for_each = local.cloud_reconciler_cluster_rules
    content {
      api_groups     = rule.value.api_groups
      resources      = rule.value.resources
      verbs          = rule.value.verbs
      resource_names = rule.value.resource_names
    }
  }
}

resource "kubernetes_cluster_role_binding" "cloud_reconciler" {
  metadata { name = "cloud-reconciler" }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.cloud_reconciler.metadata[0].name
    namespace = module.console.namespace
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.cloud_reconciler.metadata[0].name
  }
}

# Not bound here. The reconciler binds it to itself with a RoleBinding in each
# Project namespace it creates; RBAC lets it bind this role and no other.
resource "kubernetes_cluster_role" "cloud_reconciler_project" {
  metadata { name = local.cloud_project_role_name }
  dynamic "rule" {
    for_each = local.cloud_reconciler_project_rules
    content {
      api_groups     = rule.value.api_groups
      resources      = rule.value.resources
      verbs          = rule.value.verbs
      resource_names = rule.value.resource_names
    }
  }
}

# The policies with the homelab's taken hosts written in (taken_hosts.tf).
resource "kubernetes_manifest" "cloud_admission_policy" {
  for_each = { for k, v in local.cloud_admission_policies_applied : k => v if v.kind == "ValidatingAdmissionPolicy" }
  manifest = each.value
}

resource "kubernetes_manifest" "cloud_admission_policy_binding" {
  for_each   = { for k, v in local.cloud_admission_policies_applied : k => v if v.kind == "ValidatingAdmissionPolicyBinding" }
  manifest   = each.value
  depends_on = [kubernetes_manifest.cloud_admission_policy]
}

# Network floor for every Project, owned by this repo: Calico tier "cloud" and
# its two GlobalNetworkPolicies, local.cloud_project_egress_floor and
# local.cloud_project_ingress_floor in access_rules.tf (the rules and why).
# The reconciler writes each Project's own Calico policy in the default tier
# (Cloud v1 plan: order below 2000, ending in Deny). Tier "cloud" runs first,
# so that policy can only narrow what the floor passes. The reconciler holds
# `get` on tier default only (access_rules.tf), so it cannot read or write
# this tier.
resource "kubectl_manifest" "cloud_tier" {
  yaml_body = yamlencode(local.cloud_tier)
}

resource "kubectl_manifest" "cloud_project_egress_floor" {
  yaml_body  = yamlencode(local.cloud_project_egress_floor)
  depends_on = [kubectl_manifest.cloud_tier]
}

resource "kubectl_manifest" "cloud_project_ingress_floor" {
  yaml_body  = yamlencode(local.cloud_project_ingress_floor)
  depends_on = [kubectl_manifest.cloud_tier]
}

# The live host guard: Kyverno ValidatingPolicy cloud-ingress-live-hosts,
# the second check on Project Ingress hosts next to cloud-managed-ingress
# (local.cloud_live_host_guard in access_rules.tf, the rules and why). Here,
# not in stacks/kyverno, because it is part of Cloud's admission boundary:
# it uses this stack's labels and host rules, and tests/cloud-access.test.sh
# applies it from the same locals as the other policies.
resource "kubernetes_cluster_role" "cloud_live_host_guard_kyverno" {
  metadata {
    name   = local.cloud_live_host_guard_kyverno_role.name
    labels = local.cloud_live_host_guard_kyverno_role.labels
  }
  dynamic "rule" {
    for_each = local.cloud_live_host_guard_kyverno_role.rules
    content {
      api_groups     = rule.value.api_groups
      resources      = rule.value.resources
      verbs          = rule.value.verbs
      resource_names = rule.value.resource_names
    }
  }
}

resource "kubectl_manifest" "cloud_live_host_guard" {
  yaml_body = yamlencode(local.cloud_live_host_guard)
  # Kyverno must be able to read IngressRoutes before the policy admits
  # anything.
  depends_on = [kubernetes_cluster_role.cloud_live_host_guard_kyverno]
  # As in stacks/kyverno: a replacement is created before the old policy
  # goes, so admission is never uncovered.
  lifecycle {
    create_before_destroy = true
  }
}
