variable "tls_secret_name" {}
variable "tier" { type = string }

resource "kubernetes_namespace" "city-guesser" {
  metadata {
    name = "city-guesser"
    labels = {
      "istio-injection" : "disabled"
      tier = var.tier
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "city-guesser"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "city-guesser" {
  metadata {
    name      = "city-guesser"
    namespace = "city-guesser"
    labels = {
      run  = "city-guesser"
      tier = var.tier
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
  source          = "../ingress_factory"
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
#   source = "../oauth-proxy"
#   # oauth_client_id     = "3d8ce4bf7b893899d967"
#   # oauth_client_secret = "08dca09b05e511cfa7f85cd7f85c332fd0768113"
#   client_id       = "3d8ce4bf7b893899d967"
#   client_secret   = "08dca09b05e511cfa7f85cd7f85c332fd0768113"
#   namespace       = "city-guesser"
#   host            = "city-guesser.viktorbarzin.me"
#   tls_secret_name = var.tls_secret_name
#   svc_name        = "city-guesser-oauth"
# }
