variable "tls_secret_name" {}
resource "kubernetes_namespace" "flaresolverr" {
  metadata {
    name = "flaresolverr"
    # labels = {
    #   "istio-injection" : "enabled"
    # }
  }
}


module "tls_secret" {
  source          = "../../setup_tls_secret"
  namespace       = "flaresolverr"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "flaresolverr" {
  metadata {
    name      = "flaresolverr"
    namespace = "flaresolverr"
    labels = {
      app = "flaresolverr"
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "flaresolverr"
      }
    }
    template {
      metadata {
        labels = {
          app = "flaresolverr"
        }
      }
      spec {
        container {
          image = "ghcr.io/flaresolverr/flaresolverr:latest"
          name  = "flaresolverr"

          port {
            container_port = 8191
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "flaresolverr" {
  metadata {
    name      = "flaresolverr"
    namespace = "flaresolverr"
    labels = {
      app = "flaresolverr"
    }
  }

  spec {
    selector = {
      app = "flaresolverr"
    }
    port {
      name = "http"
      port = 8191
    }
  }
}

resource "kubernetes_ingress_v1" "flaresolverr" {
  metadata {
    name      = "flaresolverr"
    namespace = "flaresolverr"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
      # "nginx.ingress.kubernetes.io/auth-url" : "https://oauth2.viktorbarzin.me/oauth2/auth"
      # "nginx.ingress.kubernetes.io/auth-signin" : "https://oauth2.viktorbarzin.me/oauth2/start?rd=/redirect/$http_host$escaped_request_uri"

      "nginx.ingress.kubernetes.io/auth-url"    = "http://ak-outpost-authentik-embedded-outpost.authentik.svc.cluster.local:9000/outpost.goauthentik.io/auth/nginx"
      "nginx.ingress.kubernetes.io/auth-signin" = "https://authentik.viktorbarzin.me/outpost.goauthentik.io/start?rd=$scheme%3A%2F%2F$host$escaped_request_uri"

      "nginx.ingress.kubernetes.io/auth-response-headers" = "Set-Cookie,X-authentik-username,X-authentik-groups,X-authentik-email,X-authentik-name,X-authentik-uid"
      "nginx.ingress.kubernetes.io/auth-snippet"          = "proxy_set_header X-Forwarded-Host $http_host;"
    }
  }

  spec {
    tls {
      hosts       = ["flaresolverr.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "flaresolverr.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "flaresolverr"
              port {
                number = 8191
              }
            }
          }
        }
      }
    }
  }
}
