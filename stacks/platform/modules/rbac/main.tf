variable "tls_secret_name" {}
variable "tier" { type = string }

variable "k8s_users" {
  type = map(object({
    role       = string                     # "admin", "power-user", "namespace-owner"
    email      = string                     # OIDC email claim
    namespaces = optional(list(string), []) # for namespace-owners
    quota = optional(object({
      cpu_requests    = optional(string, "2")
      memory_requests = optional(string, "4Gi")
      cpu_limits      = optional(string, "4")
      memory_limits   = optional(string, "8Gi")
      pods            = optional(string, "20")
    }), {})
  }))
  default = {}
}

# --- Admin role ---
# Binds to built-in cluster-admin ClusterRole

resource "kubernetes_cluster_role_binding" "admin_users" {
  for_each = { for name, user in var.k8s_users : name => user if user.role == "admin" }

  metadata {
    name = "oidc-admin-${each.key}"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind      = "User"
    name      = each.value.email
    api_group = "rbac.authorization.k8s.io"
  }
}

# --- Power-user role ---
# Can manage workloads cluster-wide but cannot modify RBAC, nodes, or persistent volumes

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

resource "kubernetes_cluster_role_binding" "power_users" {
  for_each = { for name, user in var.k8s_users : name => user if user.role == "power-user" }

  metadata {
    name = "oidc-power-user-${each.key}"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.power_user.metadata[0].name
  }

  subject {
    kind      = "User"
    name      = each.value.email
    api_group = "rbac.authorization.k8s.io"
  }
}

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

resource "kubernetes_role_binding" "namespace_owner" {
  for_each = { for pair in local.namespace_owner_pairs : "${pair.user_key}-${pair.namespace}" => pair }

  metadata {
    name      = "namespace-owner-${each.value.user_key}"
    namespace = each.value.namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "admin" # Built-in ClusterRole with full namespace access
  }

  subject {
    kind      = "User"
    name      = each.value.email
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

resource "kubernetes_cluster_role_binding" "namespace_owner_readonly" {
  for_each = { for name, user in var.k8s_users : name => user if user.role == "namespace-owner" }

  metadata {
    name = "oidc-ns-owner-readonly-${each.key}"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.namespace_owner_readonly.metadata[0].name
  }

  subject {
    kind      = "User"
    name      = each.value.email
    api_group = "rbac.authorization.k8s.io"
  }
}

# Resource quotas per user namespace
resource "kubernetes_resource_quota" "user_namespace_quota" {
  for_each = { for pair in local.namespace_owner_pairs : "${pair.user_key}-${pair.namespace}" => pair }

  metadata {
    name      = "user-quota"
    namespace = each.value.namespace
  }

  spec {
    hard = {
      "requests.cpu"    = each.value.quota.cpu_requests
      "requests.memory" = each.value.quota.memory_requests
      "limits.cpu"      = each.value.quota.cpu_limits
      "limits.memory"   = each.value.quota.memory_limits
      "pods"            = each.value.quota.pods
    }
  }

  depends_on = [kubernetes_role_binding.namespace_owner]
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
