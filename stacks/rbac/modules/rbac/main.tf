variable "tls_secret_name" {}
variable "tier" { type = string }

variable "k8s_users" {
  type = map(object({
    role       = string                     # "admin", "power-user", "namespace-owner"
    email      = string                     # OIDC email claim
    namespaces = optional(list(string), []) # for namespace-owners
    domains    = optional(list(string), []) # subdomains for user apps
    quota = optional(object({
      cpu_requests    = optional(string, "2")
      memory_requests = optional(string, "4Gi")
      memory_limits   = optional(string, "8Gi")
      pods            = optional(string, "20")
    }), {})
  }))
  default = {}
}

# --- Admin role ---
# Granted through the Authentik group kubernetes-admins (oidc-group-bindings.tf)
# since 2026-11-15, not per email (enforced-identity plan, step 7). The
# per-email bindings matched the k8s_users email, which had drifted from the
# Authentik user for Viktor.

# Two more per-email admin bindings, oidc-admin-vbarzin and oidc-admin-akadmin,
# had been made with `kubectl create` on 2026-02-17 and were in no state. They
# were adopted and removed on 2026-11-15; both people are in kubernetes-admins.

# --- Power-user role (read+write+secrets) — RETAINED BUT UNBOUND ---
# Superseded by oidc-power-user-readonly (below) per ADR-0005: power-users are bound
# to the read-only role, NOT this one. Kept defined for reference/rollback; do NOT
# bind it without a deliberate decision (it grants cluster-wide write + secrets).

resource "kubernetes_cluster_role" "power_user" {
  metadata {
    name = "oidc-power-user"
  }

  # Core resources
  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log", "pods/exec", "services", "endpoints", "configmaps", "secrets", "persistentvolumeclaims", "events", "namespaces"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "services", "configmaps", "secrets", "persistentvolumeclaims"]
    verbs      = ["create", "update", "patch", "delete"]
  }

  # Apps
  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "statefulsets", "daemonsets", "replicasets"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  # Batch
  rule {
    api_groups = ["batch"]
    resources  = ["jobs", "cronjobs"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  # Networking
  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["ingresses", "networkpolicies"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  # Autoscaling
  rule {
    api_groups = ["autoscaling"]
    resources  = ["horizontalpodautoscalers"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  # Read-only on cluster-level resources
  rule {
    api_groups = [""]
    resources  = ["nodes"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["storage.k8s.io"]
    resources  = ["storageclasses"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["rbac.authorization.k8s.io"]
    resources  = ["clusterroles", "clusterrolebindings", "roles", "rolebindings"]
    verbs      = ["get", "list", "watch"]
  }
}

# --- Power-user READ-ONLY role (ADR-0005) ---
# Cluster-wide get/list/watch, explicitly NO secrets and NO pods/exec. This is the
# role power-users are actually bound to (workstation tier: "cluster-wide read,
# no Secrets"). Mirrors power_user's resource breadth minus writes/secrets/exec.
resource "kubernetes_cluster_role" "power_user_readonly" {
  metadata {
    name = "oidc-power-user-readonly"
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "pods/log", "services", "endpoints", "configmaps", "persistentvolumeclaims", "events", "namespaces", "nodes"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "statefulsets", "daemonsets", "replicasets"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["batch"]
    resources  = ["jobs", "cronjobs"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["ingresses", "networkpolicies"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["autoscaling"]
    resources  = ["horizontalpodautoscalers"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["storage.k8s.io"]
    resources  = ["storageclasses"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["rbac.authorization.k8s.io"]
    resources  = ["clusterroles", "clusterrolebindings", "roles", "rolebindings"]
    verbs      = ["get", "list", "watch"]
  }
}

# Power-users get the READ-ONLY role through the Authentik group
# kubernetes-power-users (oidc-group-bindings.tf), not per email, since
# 2026-11-15.

# --- Namespace-owner role ---
# Full admin within assigned namespaces + read-only cluster-wide

locals {
  # Flatten user->namespace pairs for iteration
  namespace_owner_pairs = flatten([
    for name, user in var.k8s_users : [
      for ns in user.namespaces : {
        user_key  = name
        namespace = ns
        email     = user.email
        quota     = user.quota
      }
    ] if user.role == "namespace-owner"
  ])
}

# admin inside each owned namespace, for the Authentik group
# kubernetes-namespace-owner-<ns> (stacks/authentik/rights-groups.tf, filled
# from the same k8s_users map). Per email until 2026-11-15.
resource "kubernetes_role_binding" "namespace_owner_group" {
  for_each = nonsensitive(toset([for pair in local.namespace_owner_pairs : pair.namespace]))

  metadata {
    name      = "namespace-owner"
    namespace = each.value
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "admin" # Built-in ClusterRole with full namespace access
  }

  subject {
    kind      = "Group"
    name      = "kubernetes-namespace-owner-${each.value}"
    api_group = "rbac.authorization.k8s.io"
  }
}

# The same admin for the owner's agent sessions, which arrive with the group
# under the `agent:` prefix (apiserver-oidc.tf).
resource "kubernetes_role_binding" "namespace_owner_agent_group" {
  for_each = nonsensitive(toset([for pair in local.namespace_owner_pairs : pair.namespace]))

  metadata {
    name      = "namespace-owner-agent"
    namespace = each.value
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "admin"
  }

  subject {
    kind      = "Group"
    name      = "agent:kubernetes-namespace-owner-${each.value}"
    api_group = "rbac.authorization.k8s.io"
  }
}

# Read-only cluster-wide access for namespace owners
resource "kubernetes_cluster_role" "namespace_owner_readonly" {
  metadata {
    name = "oidc-namespace-owner-readonly"
  }

  rule {
    api_groups = [""]
    resources  = ["namespaces", "nodes"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["pods", "services", "configmaps", "events"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["deployments", "statefulsets", "daemonsets"]
    verbs      = ["get", "list", "watch"]
  }
}

# Namespace owners get the read-only role above through the Authentik group
# kubernetes-namespace-owners (oidc-group-bindings.tf) since 2026-11-15.

# Resource quotas per user namespace
resource "kubernetes_resource_quota" "user_namespace_quota" {
  for_each = nonsensitive({ for pair in local.namespace_owner_pairs : "${pair.user_key}-${pair.namespace}" => pair })

  metadata {
    name      = "user-quota"
    namespace = each.value.namespace
  }

  spec {
    hard = {
      "requests.cpu"    = each.value.quota.cpu_requests
      "requests.memory" = each.value.quota.memory_requests
      "limits.memory"   = each.value.quota.memory_limits
      "pods"            = each.value.quota.pods
    }
  }

  depends_on = [kubernetes_role_binding.namespace_owner_group]
}

# ConfigMap with user-role mapping for the self-service portal
resource "kubernetes_config_map" "user_roles" {
  metadata {
    name      = "k8s-user-roles"
    namespace = "k8s-portal"
  }

  data = {
    "users.json" = jsonencode({
      for name, user in var.k8s_users : user.email => {
        role       = user.role
        namespaces = user.namespaces
      }
    })
  }
}

# TLS secret in each user namespace (so they can create HTTPS ingresses)
module "user_namespace_tls" {
  for_each = nonsensitive(toset(flatten([
    for name, user in var.k8s_users : user.namespaces
    if user.role == "namespace-owner"
  ])))

  source          = "../../../../modules/kubernetes/setup_tls_secret"
  namespace       = each.value
  tls_secret_name = var.tls_secret_name
}
