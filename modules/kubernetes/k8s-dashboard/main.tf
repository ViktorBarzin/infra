variable "tls_secret_name" {}
variable "client_certificate_secret_name" {}

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
    }
  }
}
# }

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "kubernetes-dashboard"
  tls_secret_name = var.tls_secret_name
}

resource "helm_release" "kubernetes-dashboard" {
  namespace = "kubernetes-dashboard"
  name      = "kubernetes-dashboard"

  repository = "https://kubernetes.github.io/dashboard/"
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
#     namespace = "kubernetes-dashboard"
#     annotations = {
#       "kubernetes.io/service-account.name" : "kubernetes-dashboard"
#     }
#   }
#   type = "kubernetes.io/service-account-token"
# }


module "ingress" {
  source           = "../ingress_factory"
  namespace        = "kubernetes-dashboard"
  name             = "kubernetes-dashboard"
  service_name     = "kubernetes-dashboard-kong-proxy"
  host             = "k8s"
  tls_secret_name  = var.tls_secret_name
  protected        = true
  backend_protocol = "HTTPS"
  port             = 443
}

# create token with
# kb create token --duration=0s kubernetes-dashboard
resource "kubernetes_service_account" "kubernetes-dashboard" {
  metadata {
    name      = "kubernetes-dashboard"
    namespace = "kubernetes-dashboard"
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
    namespace = "kubernetes-dashboard"
  }
  # depends_on = [module.dashboard]
}

resource "kubernetes_secret" "kubernetes-dashboard-admin-token" {
  metadata {
    name      = "kubernetes-dashboard-admin"
    namespace = "kubernetes-dashboard"
    annotations = {
      "kubernetes.io/service-account.name" : "kubernetes-dashboard"
    }
  }
  type = "kubernetes.io/service-account-token"
}

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
    namespace = "kubernetes-dashboard"
  }
}

resource "kubernetes_service_account" "kubernetes-dashboard-viewonly" {
  metadata {
    name      = "kubernetes-dashboard-viewonly"
    namespace = "kubernetes-dashboard"
  }
}

resource "kubernetes_secret" "kubernetes-dashboard-viewonly-token" {
  metadata {
    name      = "kubernetes-dashboard-viewonly"
    namespace = "kubernetes-dashboard"
    annotations = {
      "kubernetes.io/service-account.name" : "kubernetes-dashboard-viewonly"
    }
  }
  type = "kubernetes.io/service-account-token"
}
