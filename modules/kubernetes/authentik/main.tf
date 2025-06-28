variable "tls_secret_name" {}
variable "secret_key" {}
variable "postgres_password" {}


module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "authentik"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_namespace" "authentik" {
  metadata {
    name = "authentik"
  }
}

resource "helm_release" "authentik" {
  namespace        = "authentik"
  create_namespace = true
  name             = "goauthentik"

  repository = "https://charts.goauthentik.io/"
  chart      = "authentik"
  version    = "2025.6.3"
  atomic     = true
  timeout    = 6000

  values = [templatefile("${path.module}/values.yaml", { postgres_password = var.postgres_password, secret_key = var.secret_key })]
}


resource "kubernetes_ingress_v1" "authentik" {
  metadata {
    name      = "authentik"
    namespace = "authentik"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
    }
  }

  spec {
    tls {
      hosts       = ["authentik.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "authentik.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "goauthentik-server"
              port {
                number = 80
              }
            }
          }
        }
        path {
          path      = "/outpost.goauthentik.io"
          path_type = "Prefix"
          backend {
            service {
              name = "ak-outpost-authentik-embedded-outpost"
              port {
                number = 9000
              }
            }
          }
        }
      }
    }
  }
}
