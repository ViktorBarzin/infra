variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "client_certificate_secret_name" {
  type = string
}


resource "random_password" "csrf_token" {
  length           = 16
  special          = true
  override_special = "_%@"
}

# instructions on deploying:
# https://kubernetes.io/docs/tasks/access-application-cluster/web-ui-dashboard/#accessing-the-dashboard-ui

# module "dashboard" {
#   # source = "cookielab/dashboard/kubernetes"
#   source                    = "ViktorBarzin/dashboard/kubernetes"
#   version                   = "0.13.2"
#   kubernetes_dashboard_csrf = random_password.csrf_token.result
#   kubernetes_dashboard_deployment_args = tolist([
#     "--auto-generate-certificates",
#     "--token-ttl=0"
#   ])
# }
resource "kubernetes_namespace" "k8s-dashboard" {
  metadata {
    name = "kubernetes-dashboard"
    labels = {
      "istio-injection" : "disabled"
      tier               = local.tiers.cluster
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}
# }

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.k8s-dashboard.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "helm_release" "kubernetes-dashboard" {
  namespace = kubernetes_namespace.k8s-dashboard.metadata[0].name
  name      = "kubernetes-dashboard"

  repository = "https://kubernetes-retired.github.io/dashboard/"
  chart      = "kubernetes-dashboard"
  atomic     = true
  version    = "7.12.0"

  # values = [templatefile("${path.module}/chart_values.tpl", { postgresql_password = var.postgresql_password })]
}

# # locals {
# #   resources = split("---\n", file("${path.module}/recommended.yaml"))
# # }
# # resource "k8s_manifest" "kubernetes-dashboard-manifests" {
# #   count = length(local.resources) - 1
# #   # count   = 2
# #   #   content = local.resources[1 + count.index]
# #   #   content = file("${path.module}/recommended.yaml")
# #   content    = local.resources[1]
# #   depends_on = [kubernetes_namespace.kubernetes-dashboard]
# # }
# resource "kubectl_manifest" "kubernetes-dashboard-manifests" {
#   yaml_body  = file("${path.module}/recommended.yaml")
#   force_new  = true
#   depends_on = [kubernetes_namespace.kubernetes-dashboard]
# }

# resource "kubernetes_secret" "dashboard-token" {
#   metadata {
#     name      = "dashboard-secret"
#    namespace = kubernetes_namespace.k8s-dashboard.metadata[0].name
#     annotations = {
#       "kubernetes.io/service-account.name" : "kubernetes-dashboard"
#     }
#   }
#   type = "kubernetes.io/service-account-token"
# }


module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # Scale-to-zero (ADR-0022): loading-page wake, 3h idle park.
  sablier = {
    group = "k8s-dashboard"
  }
  namespace = kubernetes_namespace.k8s-dashboard.metadata[0].name
  name      = "kubernetes-dashboard"
  # Route through the token-injector: Authentik forward-auth (auth=required) gates
  # access AND injects X-authentik-username; the injector maps that to the user's
  # ServiceAccount token and sets Authorization: Bearer so the dashboard skips its
  # token-paste login. See dashboard_injector.tf.
  service_name     = "dashboard-token-injector"
  host             = "k8s"
  dns_type         = "proxied"
  tls_secret_name  = var.tls_secret_name
  auth             = "required"
  backend_protocol = "HTTP"
  port             = 80
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Kubernetes Dashboard"
    "gethomepage.dev/description"  = "Cluster dashboard"
    "gethomepage.dev/icon"         = "kubernetes-dashboard.png"
    "gethomepage.dev/group"        = "Core Platform"
    "gethomepage.dev/pod-selector" = ""
  }
}

# create token with
# kb create token --duration=0s kubernetes-dashboard
resource "kubernetes_service_account" "kubernetes-dashboard" {
  metadata {
    name      = "kubernetes-dashboard"
    namespace = kubernetes_namespace.k8s-dashboard.metadata[0].name
  }
}

# Give cluster-admin permissions to dashboard
resource "kubernetes_cluster_role_binding" "kubernetes-dashboard" {
  metadata {
    name = "admin-user"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }
  subject {
    kind      = "ServiceAccount"
    name      = "kubernetes-dashboard"
    namespace = kubernetes_namespace.k8s-dashboard.metadata[0].name
  }
  # depends_on = [module.dashboard]
}

# Admin token: use `vault write kubernetes/creds/dashboard-admin kubernetes_namespace=kubernetes-dashboard`
# instead of a static never-expiring token.

## Readonly RBAC
resource "kubernetes_cluster_role" "kubernetes-dashboard-viewonly" {
  metadata {
    name = "kubernetes-dashboard-viewonly"
  }

  rule {
    api_groups = [""]
    resources  = ["configmaps", "endpoints", "persistentvolumeclaims", "pods", "replicationcontrollers", "replicationcontrollers/scale", "serviceaccounts", "services", "nodes", "persistentvolumeclaims", "persistentvolumes"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["bindings", "events", "limitranges", "namespaces/status", "pods/log", "pods/status", "replicationcontrollers/status", "resourcequotas", "resourcequotas/status"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = [""]
    resources  = ["namespaces"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["apps"]
    resources  = ["daemonsets", "deployments", "deployments/scale", "replicasets", "replicasets/scale", "statefulsets"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["autoscaling"]
    resources  = ["horizontalpodautoscalers"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["batch"]
    resources  = ["cronjobs", "jobs"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["extensions"]
    resources  = ["daemonsets", "deployments", "deployments/scale", "ingresses", "networkpolicies", "replicasets", "replicasets/scale", "replicationcontrollers/scale"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["policy"]
    resources  = ["poddisruptionbudgets"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["networking.k8s.io"]
    resources  = ["networkpolicies"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["storage.k8s.io"]
    resources  = ["storageclasses", "volumeattachments"]
    verbs      = ["get", "list", "watch"]
  }

  rule {
    api_groups = ["rbac.authorization.k8s.io"]
    resources  = ["clusterrolebindings", "clusterroles", "roles", "rolebindings"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding" "kubernetes-dashboard-viewonly" {
  metadata {
    name = "kubernetes-dashboard-viewonly"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "kubernetes-dashboard-viewonly"
  }
  subject {
    kind      = "ServiceAccount"
    name      = "kubernetes-dashboard-viewonly"
    namespace = kubernetes_namespace.k8s-dashboard.metadata[0].name
  }
}

resource "kubernetes_service_account" "kubernetes-dashboard-viewonly" {
  metadata {
    name      = "kubernetes-dashboard-viewonly"
    namespace = kubernetes_namespace.k8s-dashboard.metadata[0].name
  }
}

resource "kubernetes_secret" "kubernetes-dashboard-viewonly-token" {
  metadata {
    name      = "kubernetes-dashboard-viewonly"
    namespace = kubernetes_namespace.k8s-dashboard.metadata[0].name
    annotations = {
      "kubernetes.io/service-account.name" : "kubernetes-dashboard-viewonly"
    }
  }
  type = "kubernetes.io/service-account-token"
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00

# CI retrigger v3 2026-05-16T14:06:39Z

# CI retrigger v4 2026-05-16T14:13:59Z

# CI retrigger v5 2026-05-16T23:10:38Z

# CI retrigger v6 2026-05-16T23:18:58Z


# Sablier enrollment labels for the five Helm-owned dashboard Deployments
# (ADR-0022, batch 4). The chart exposes no deployment-labels surface, so a
# field-manager patch stamps them (same pattern as postiz). The two HCL-owned
# members (dashboard-token-injector, oauth2-proxy) carry their labels in HCL —
# a kubernetes_labels patch on an HCL-owned Deployment would be stripped by
# the next apply (labels are an atomic map to the kubernetes provider).
resource "kubernetes_labels" "dashboard_sablier" {
  for_each = toset([
    "kubernetes-dashboard-api",
    "kubernetes-dashboard-auth",
    "kubernetes-dashboard-kong",
    "kubernetes-dashboard-metrics-scraper",
    "kubernetes-dashboard-web",
  ])
  api_version = "apps/v1"
  kind        = "Deployment"
  metadata {
    name      = each.key
    namespace = kubernetes_namespace.k8s-dashboard.metadata[0].name
  }
  labels = {
    "sablier.enable"      = "true"
    "sablier.group"       = "k8s-dashboard"
    "sablier.ready-after" = "5s"
  }
  depends_on = [helm_release.kubernetes-dashboard]
}
