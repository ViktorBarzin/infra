variable "tls_secret_name" {}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "actualbudget"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_namespace" "actualbudget" {
  metadata {
    name = "actualbudget"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}


resource "kubernetes_deployment" "actualbudget" {
  metadata {
    name      = "actualbudget"
    namespace = "actualbudget"
    labels = {
      app = "actualbudget"
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "actualbudget"
      }
    }
    template {
      metadata {
        annotations = {
          "diun.enable" = "true"
        }
        labels = {
          app = "actualbudget"
        }
      }
      spec {
        container {
          image = "actualbudget/actual-server:latest"
          name  = "actualbudget"

          port {
            container_port = 5006
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
        }
        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/actualbudget"
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "actualbudget" {
  metadata {
    name      = "actualbudget"
    namespace = "actualbudget"
    labels = {
      app = "actualbudget"
    }
  }

  spec {
    selector = {
      app = "actualbudget"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 5006
    }
  }
}

resource "kubernetes_ingress_v1" "actualbudget" {
  metadata {
    name      = "actualbudget-ingress"
    namespace = "actualbudget"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
      "nginx.ingress.kubernetes.io/client-max-body-size" : "0"
      "nginx.ingress.kubernetes.io/proxy-body-size" : "0",
      # "nginx.ingress.kubernetes.io/auth-url" : "https://oauth2.viktorbarzin.me/oauth2/auth"
      # "nginx.ingress.kubernetes.io/auth-signin" : "https://oauth2.viktorbarzin.me/oauth2/start?rd=/redirect/$http_host$escaped_request_uri"
      "nginx.ingress.kubernetes.io/auth-url" : "http://ak-outpost-authentik-embedded-outpost.authentik.svc.cluster.local:9000/outpost.goauthentik.io/auth/nginx"
      "nginx.ingress.kubernetes.io/auth-signin" : "https://authentik.viktorbarzin.me/outpost.goauthentik.io/start?rd=$scheme%3A%2F%2F$host$escaped_request_uri"
      "nginx.ingress.kubernetes.io/auth-response-headers" : "Set-Cookie,X-authentik-username,X-authentik-groups,X-authentik-email,X-authentik-name,X-authentik-uid"
      "nginx.ingress.kubernetes.io/auth-snippet" : "proxy_set_header X-Forwarded-Host $http_host;"
    }
  }

  spec {
    tls {
      hosts       = ["budget.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "budget.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "actualbudget"
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

