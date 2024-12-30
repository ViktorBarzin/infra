variable "tls_secret_name" {}
variable "postgresql_password" {}
variable "authentik_client_id" {}
variable "authentik_client_secret" {}

resource "kubernetes_namespace" "linkwarden" {
  metadata {
    name = "linkwarden"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "linkwarden"
  tls_secret_name = var.tls_secret_name
}

resource "random_string" "secret" {
  length           = 32
  special          = true
  override_special = "/@£$"
}

resource "kubernetes_deployment" "linkwarden" {
  metadata {
    name      = "linkwarden"
    namespace = "linkwarden"
    labels = {
      app = "linkwarden"
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "linkwarden"
      }
    }
    template {
      metadata {
        labels = {
          app = "linkwarden"
        }
        annotations = {
          "diun.enable"       = "true"
          "diun.include_tags" = "latest"
        }
      }
      spec {
        container {
          image = "ghcr.io/linkwarden/linkwarden:latest"
          name  = "linkwarden"

          port {
            container_port = 3000
          }
          env {
            name  = "DATABASE_URL"
            value = "postgresql://linkwarden:${var.postgresql_password}@postgresql.dbaas.svc.cluster.local:5432/linkwarden"
          }
          env {
            name  = "NEXT_PUBLIC_AUTHENTIK_ENABLED"
            value = "true"
          }
          env {
            name  = "NEXTAUTH_SECRET"
            value = random_string.secret.result
          }
          env {
            name  = "NEXTAUTH_URL"
            value = "https://linkwarden.viktorbarzin.me/api/v1/auth"
          }
          env {
            name  = "AUTHENTIK_ISSUER"
            value = "https://authentik.viktorbarzin.me/application/o/linkwarden"
          }
          env {
            name  = "AUTHENTIK_CLIENT_ID"
            value = var.authentik_client_id
          }
          env {
            name  = "AUTHENTIK_CLIENT_SECRET"
            value = var.authentik_client_secret
          }
        }
      }
    }
  }
}
resource "kubernetes_service" "linkwarden" {
  metadata {
    name      = "linkwarden"
    namespace = "linkwarden"
    labels = {
      app = "linkwarden"
    }
  }

  spec {
    selector = {
      app = "linkwarden"
    }
    port {
      name        = "linkwarden"
      port        = 80
      target_port = 3000
    }
  }
}
resource "kubernetes_ingress_v1" "linkwarden" {
  metadata {
    name      = "linkwarden"
    namespace = "linkwarden"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
      # "nginx.ingress.kubernetes.io/auth-url" : "https://oauth2.viktorbarzin.me/oauth2/auth"
      # "nginx.ingress.kubernetes.io/auth-signin" : "https://oauth2.viktorbarzin.me/oauth2/start?rd=/redirect/$http_host$escaped_request_uri"
      #   "nginx.ingress.kubernetes.io/auth-url" : "http://ak-outpost-authentik-embedded-outpost.authentik.svc.cluster.local:9000/outpost.goauthentik.io/auth/nginx"
      #   "nginx.ingress.kubernetes.io/auth-signin" : "https://authentik.viktorbarzin.me/outpost.goauthentik.io/start?rd=$scheme%3A%2F%2F$host$escaped_request_uri"

      #   "nginx.ingress.kubernetes.io/auth-response-headers" : "Set-Cookie,X-authentik-username,X-authentik-groups,X-authentik-email,X-authentik-name,X-authentik-uid"
      #   "nginx.ingress.kubernetes.io/auth-snippet" : "proxy_set_header X-Forwarded-Host $http_host;"
      "nginx.ingress.kubernetes.io/ssl-passthrough" : true
    }
  }

  spec {
    tls {
      hosts       = ["linkwarden.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "linkwarden.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "linkwarden"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}
