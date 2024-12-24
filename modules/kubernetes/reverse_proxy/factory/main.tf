variable "name" {}
variable "namespace" {
  default = "reverse-proxy"
}
variable "external_name" {}
variable "port" {
  default = "80"
}
variable "tls_secret_name" {}
variable "backend_protocol" {
  default = "HTTP"
}
variable "protected" {
  type    = bool
  default = true
}
variable "ingress_path" {
  type    = list(string)
  default = ["/"]
}
variable "max_body_size" {
  type    = string
  default = "50m"
}
variable "use_proxy_protocol" {
  type    = bool
  default = true
}
variable "proxy_timeout" {
  type    = number
  default = 60
}
variable "extra_annotations" {
  default = {}
}


resource "kubernetes_service" "proxied-service" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels = {
      "app" = var.name
    }
  }

  spec {
    type          = "ExternalName"
    external_name = var.external_name

    port {
      name        = "${var.name}-web"
      port        = var.port
      protocol    = "TCP"
      target_port = var.port
    }
  }
}

resource "kubernetes_ingress_v1" "proxied-ingress" {
  metadata {
    name      = var.name
    namespace = var.namespace
    annotations = merge({
      "nginx.ingress.kubernetes.io/backend-protocol" = "${var.backend_protocol}"
      "kubernetes.io/ingress.class"                  = "nginx"
      # "nginx.ingress.kubernetes.io/auth-url" : var.protected ? "https://oauth2.viktorbarzin.me/oauth2/auth" : null
      # "nginx.ingress.kubernetes.io/auth-signin" : var.protected ? "https://oauth2.viktorbarzin.me/oauth2/start?rd=/redirect/$http_host$escaped_request_uri" : null
      # Do not do hairpinning
      # "nginx.ingress.kubernetes.io/auth-url" : var.protected ? "http://oauth2.oauth2.svc.cluster.local/oauth2/auth" : null
      # "nginx.ingress.kubernetes.io/auth-signin" : var.protected ? "http://oauth2.oauth2.svc.cluster.local/oauth2/start?rd=/redirect/$http_host$escaped_request_uri" : null

      "nginx.ingress.kubernetes.io/auth-url" : var.protected ? "http://ak-outpost-authentik-embedded-outpost.authentik.svc.cluster.local:9000/outpost.goauthentik.io/auth/nginx" : null
      "nginx.ingress.kubernetes.io/auth-signin" : var.protected ? "https://authentik.viktorbarzin.me/outpost.goauthentik.io/start?rd=$scheme%3A%2F%2F$host$escaped_request_uri" : null
      # "nginx.ingress.kubernetes.io/auth-response-headers" : var.protected ? "Set-Cookie,X-authentik-username,X-authentik-groups,X-authentik-email,X-authentik-name,X-authentik-uid" : null
      "nginx.ingress.kubernetes.io/auth-snippet" : var.protected ? "proxy_set_header X-Forwarded-Host $http_host;" : null

      "nginx.ingress.kubernetes.io/proxy-body-size" : var.max_body_size
      "nginx.ingress.kubernetes.io/use-proxy-protocol" : var.use_proxy_protocol
      "nginx.ingress.kubernetes.io/proxy-connect-timeout" : var.proxy_timeout
      "nginx.ingress.kubernetes.io/proxy-send-timeout" : var.proxy_timeout
      "nginx.ingress.kubernetes.io/proxy-read-timeout" : var.proxy_timeout

    }, var.extra_annotations)
  }

  spec {
    tls {
      hosts       = ["${var.name}.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "${var.name}.viktorbarzin.me"
      http {
        dynamic "path" {
          # for_each = { for pr in var.ingress_path : pr => pr }
          for_each = var.ingress_path

          content {
            path = path.value
            backend {
              service {

                name = var.name
                port {
                  number = var.port
                }
              }
            }
          }
        }
        # path {
        #   # path = var.ingress_path
        #   path = each.value
        # }
      }
    }
  }
}
