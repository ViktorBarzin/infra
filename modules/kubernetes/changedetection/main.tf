variable "tls_secret_name" {}

resource "kubernetes_namespace" "changedetection" {
  metadata {
    name = "changedetection"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "changedetection"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "changedetection" {
  metadata {
    name      = "changedetection"
    namespace = "changedetection"
    labels = {
      app = "changedetection"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "changedetection"
      }
    }
    template {
      metadata {
        labels = {
          app = "changedetection"
        }
      }
      spec {
        container {
          name              = "sockpuppetbrowser"
          image             = "dgtlmoon/sockpuppetbrowser:latest"
          image_pull_policy = "IfNotPresent"
          port {
            name           = "ws"
            container_port = 3000
            protocol       = "TCP"
          }
          security_context {
            capabilities {
              add = ["SYS_ADMIN"]
            }
          }
        }

        container {
          name  = "changedetection"
          image = "ghcr.io/dgtlmoon/changedetection.io:latest" # latest is latest stable
          env {
            name  = "PLAYWRIGHT_DRIVER_URL"
            value = "ws://localhost:3000"
          }
          env {
            name  = "BASE_URL"
            value = "https://changedetection.viktorbarzin.me"
          }
          env {
            name  = "LOGGER_LEVEL"
            value = "WARNING"
          }
          env {
            name  = "TZ"
            value = "Europe/Sofia"
          }
          volume_mount {
            name       = "data"
            mount_path = "/datastore"
          }
          port {
            name           = "http"
            container_port = 5000
            protocol       = "TCP"
          }
        }
        # security_context {
        #   fs_group = "1500"
        # }
        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/changedetection"
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "changedetection" {
  metadata {
    name      = "changedetection"
    namespace = "changedetection"
    labels = {
      "app" = "changedetection"
    }
  }

  spec {
    selector = {
      app = "changedetection"
    }
    port {
      port        = 80
      target_port = 5000
    }
  }
}

resource "kubernetes_ingress_v1" "changedetection" {
  metadata {
    name      = "changedetection-ingress"
    namespace = "changedetection"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
      "nginx.ingress.kubernetes.io/auth-url" : "http://ak-outpost-authentik-embedded-outpost.authentik.svc.cluster.local:9000/outpost.goauthentik.io/auth/nginx"
      "nginx.ingress.kubernetes.io/auth-signin" : "https://authentik.viktorbarzin.me/outpost.goauthentik.io/start?rd=$scheme%3A%2F%2F$host$escaped_request_uri"

      "nginx.ingress.kubernetes.io/auth-response-headers" : "Set-Cookie,X-authentik-username,X-authentik-groups,X-authentik-email,X-authentik-name,X-authentik-uid"
      "nginx.ingress.kubernetes.io/auth-snippet" : "proxy_set_header X-Forwarded-Host $http_host;"
    }
  }

  spec {
    tls {
      hosts       = ["changedetection.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "changedetection.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "changedetection"
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
