variable "tls_secret_name" { type = string }

locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

resource "kubernetes_namespace" "city-guesser" {
  metadata {
    name = "city-guesser"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = "city-guesser"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "city-guesser" {
  metadata {
    name      = "city-guesser"
    namespace = "city-guesser"
    labels = {
      run  = "city-guesser"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        run = "city-guesser"
      }
    }
    template {
      metadata {
        labels = {
          run = "city-guesser"
        }
      }
      spec {
        container {
          image = "viktorbarzin/city-guesser:latest"
          name  = "city-guesser"
          resources {
            limits = {
              cpu    = "0.5"
              memory = "512Mi"
            }
            requests = {
              cpu    = "250m"
              memory = "50Mi"
            }
          }
          port {
            container_port = 80
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "city-guesser" {
  metadata {
    name      = "city-guesser"
    namespace = "city-guesser"
    labels = {
      "run" = "city-guesser"
    }
  }

  spec {
    selector = {
      run = "city-guesser"
    }
    port {
      name        = "http"
      port        = "80"
      target_port = "80"
    }
  }
}
# resource "kubernetes_service" "city-guesser-oauth" {
#   metadata {
#     name      = "city-guesser-oauth"
#     namespace = "city-guesser"
#     labels = {
#       "run" = "city-guesser-oauth"
#     }
#   }

#   spec {
#     type          = "ExternalName"
#     external_name = "oauth-proxy.oauth.svc.cluster.local"

#     # port {
#     #   name        = "tcp"
#     #   port        = "80"
#     #   target_port = "80"
#     # }
#   }
# }

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = "city-guesser"
  name            = "city-guesser"
  tls_secret_name = var.tls_secret_name
  protected       = true
}

# resource "kubernetes_ingress_v1" "city-guesser-oauth" {
#   metadata {
#     name      = "city-guesser-ingress-oauth"
#     namespace = "city-guesser"
#     annotations = {
#       "kubernetes.io/ingress.class" = "nginx"
#     }
#   }

#   spec {
#     tls {
#       hosts       = ["city-guesser.viktorbarzin.me"]
#       secret_name = var.tls_secret_name
#     }
#     rule {
#       host = "city-guesser.viktorbarzin.me"
#       http {
#         path {
#           path = "/oauth2"
#           backend {
#             service_name = "city-guesser-oauth"
#             service_port = "80"
#           }
#         }
#       }
#     }
#   }
# }


# module "oauth" {
#   source = "../../modules/kubernetes/oauth-proxy"
#   # oauth_client_id     = "3d8ce4bf7b893899d967"
#   # oauth_client_secret = "REDACTED_OAUTH_SECRET"
#   client_id       = "3d8ce4bf7b893899d967"
#   client_secret   = "REDACTED_OAUTH_SECRET"
#   namespace       = "city-guesser"
#   host            = "city-guesser.viktorbarzin.me"
#   tls_secret_name = var.tls_secret_name
#   svc_name        = "city-guesser-oauth"
# }
