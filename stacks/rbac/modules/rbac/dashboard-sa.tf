# Per-namespace-owner ServiceAccount + long-lived token for Kubernetes Dashboard
# token-paste access.
#
# WHY: seamless OIDC SSO into the dashboard is blocked — the apiserver currently
# rejects all Authentik OIDC tokens (see docs/plans/2026-06-04-k8s-dashboard-sso-design.md
# §12). Until that's solved, each namespace-owner gets a ServiceAccount scoped to
# `admin` on their namespace(s) + cluster read-only, and a long-lived token they
# paste into the dashboard "Token" login. Real per-namespace isolation, no OIDC
# dependency. Rotate a token by deleting+recreating its `dashboard-<user>-token`
# Secret. Retrieve with:
#   kubectl -n <ns> get secret dashboard-<user>-token -o jsonpath='{.data.token}' | base64 -d
#
# Driven by the same `local.namespace_owner_pairs` as the OIDC bindings, so every
# namespace-owner in k8s_users automatically gets one.

resource "kubernetes_service_account" "dashboard_owner" {
  for_each = nonsensitive({ for pair in local.namespace_owner_pairs : "${pair.user_key}-${pair.namespace}" => pair })

  metadata {
    name      = "dashboard-${each.value.user_key}"
    namespace = each.value.namespace
  }
}

# Full admin within the owner's namespace (same scope as their OIDC RoleBinding).
resource "kubernetes_role_binding" "dashboard_owner_admin" {
  for_each = nonsensitive({ for pair in local.namespace_owner_pairs : "${pair.user_key}-${pair.namespace}" => pair })

  metadata {
    name      = "dashboard-owner-${each.value.user_key}"
    namespace = each.value.namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "admin"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.dashboard_owner[each.key].metadata[0].name
    namespace = each.value.namespace
  }
}

# Minimal cluster-read for the dashboard nav ONLY: the namespace picker needs to
# list namespaces, and the Nodes view needs nodes. Deliberately does NOT grant
# cluster-wide read of pods/services/configmaps/etc — a namespace-owner can see
# the namespace LIST but can only read resources INSIDE their own namespace
# (where they have `admin`). Keeps tenants from reading each other's workloads
# and configmaps. (Separate from the broader OIDC `namespace_owner_readonly`.)
resource "kubernetes_cluster_role" "dashboard_nav_readonly" {
  metadata {
    name = "dashboard-nav-readonly"
  }
  rule {
    api_groups = [""]
    resources  = ["namespaces", "nodes"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding" "dashboard_owner_readonly" {
  for_each = nonsensitive({ for pair in local.namespace_owner_pairs : "${pair.user_key}-${pair.namespace}" => pair })

  metadata {
    name = "dashboard-readonly-${each.value.user_key}-${each.value.namespace}"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.dashboard_nav_readonly.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.dashboard_owner[each.key].metadata[0].name
    namespace = each.value.namespace
  }
}

# Long-lived (non-expiring) token the user pastes into the dashboard login.
resource "kubernetes_secret" "dashboard_owner_token" {
  for_each = nonsensitive({ for pair in local.namespace_owner_pairs : "${pair.user_key}-${pair.namespace}" => pair })

  metadata {
    name      = "dashboard-${each.value.user_key}-token"
    namespace = each.value.namespace
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account.dashboard_owner[each.key].metadata[0].name
    }
  }
  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}
