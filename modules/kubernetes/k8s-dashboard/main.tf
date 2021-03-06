variable "tls_secret_name" {}
variable "client_certificate_secret_name" {}

resource "random_password" "csrf_token" {
  length           = 16
  special          = true
  override_special = "_%@"
}

module "dashboard" {
  # source = "cookielab/dashboard/kubernetes"
  source                    = "ViktorBarzin/dashboard/kubernetes"
  version                   = "0.13.1"
  kubernetes_dashboard_csrf = random_password.csrf_token.result
  kubernetes_dashboard_deployment_args = list(
    "--auto-generate-certificates",
    "--token-ttl=0"
  )
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "kubernetes-dashboard"
  tls_secret_name = var.tls_secret_name
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

resource "kubernetes_ingress" "kubernetes-dashboard" {
  metadata {
    name      = "kubernetes-dashboard"
    namespace = "kubernetes-dashboard"
    annotations = {
      "kubernetes.io/ingress.class"                        = "nginx"
      "nginx.ingress.kubernetes.io/backend-protocol"       = "HTTPS"
      "nginx.ingress.kubernetes.io/force-ssl-redirect"     = "true"
      "nginx.ingress.kubernetes.io/auth-tls-verify-client" = "on"
      "nginx.ingress.kubernetes.io/auth-tls-secret"        = var.client_certificate_secret_name

      # "nginx.ingress.kubernetes.io/auth-url"    = "https://$host/oauth2/auth"
      # "nginx.ingress.kubernetes.io/auth-signin" = "https://$host/oauth2/start?rd=$escaped_request_uri"
    }
  }

  spec {
    tls {
      hosts       = ["k8s.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "k8s.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service_name = "kubernetes-dashboard"
            service_port = "443"
          }
        }
      }
    }
  }
  depends_on = [module.dashboard]
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
  depends_on = [module.dashboard]
}

# resource "kubernetes_ingress" "oauth" {
#   metadata {
#     name      = "kubernetes-dashboard"
#     namespace = "oauth"
#     annotations = {
#       "kubernetes.io/ingress.class"                    = "nginx"
#       "nginx.ingress.kubernetes.io/force-ssl-redirect" = "true"

#     }
#   }

#   spec {
#     tls {
#       hosts       = ["k8s.viktorbarzin.me"]
#       secret_name = var.tls_secret_name
#     }
#     rule {
#       host = "k8s.viktorbarzin.me"
#       http {
#         path {
#           path = "/oauth2"
#           backend {
#             service_name = "oauth-proxy"
#             service_port = "80"
#           }
#         }
#       }
#     }
#   }
#   depends_on = [module.dashboard]
# }
