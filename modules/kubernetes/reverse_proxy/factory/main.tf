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
variable "extra_annotations" {
  default = {}
}
variable "rybbit_site_id" {
  default = null
  type    = string
}
variable "custom_content_security_policy" {
  default = null
  type    = string
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
      name        = var.backend_protocol == "HTTPS" ? "https-${var.name}" : "${var.name}-web"
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
      "traefik.ingress.kubernetes.io/router.middlewares" = join(",", compact([
        "traefik-rate-limit@kubernetescrd",
        var.custom_content_security_policy == null ? "traefik-csp-headers@kubernetescrd" : null,
        "traefik-crowdsec@kubernetescrd",
        var.protected ? "traefik-authentik-forward-auth@kubernetescrd" : null,
        var.rybbit_site_id != null ? "${var.namespace}-rybbit-analytics-${var.name}@kubernetescrd" : null,
        var.custom_content_security_policy != null ? "${var.namespace}-custom-csp-${var.name}@kubernetescrd" : null,
      ]))
      "traefik.ingress.kubernetes.io/router.entrypoints"    = "websecure"
      "traefik.ingress.kubernetes.io/service.serversscheme"  = var.backend_protocol == "HTTPS" ? "https" : null
      "traefik.ingress.kubernetes.io/service.serverstransport" = var.backend_protocol == "HTTPS" ? "traefik-insecure-skip-verify@kubernetescrd" : null
    }, var.extra_annotations)
  }

  spec {
    ingress_class_name = "traefik"
    tls {
      hosts       = ["${var.name}.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "${var.name}.viktorbarzin.me"
      http {
        dynamic "path" {
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
      }
    }
  }
}

# Rybbit analytics middleware (rewritebody plugin) - created per service when rybbit_site_id is set
resource "kubernetes_manifest" "rybbit_analytics" {
  count = var.rybbit_site_id != null ? 1 : 0

  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "rybbit-analytics-${var.name}"
      namespace = var.namespace
    }
    spec = {
      plugin = {
        rewritebody = {
          rewrites = [{
            regex       = "</head>"
            replacement = "<script src=\"https://rybbit.viktorbarzin.me/api/script.js\" data-site-id=\"${var.rybbit_site_id}\" defer></script></head>"
          }]
        }
      }
    }
  }
}

# Custom CSP headers middleware - created per service when custom_content_security_policy is set
resource "kubernetes_manifest" "custom_csp" {
  count = var.custom_content_security_policy != null ? 1 : 0

  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "custom-csp-${var.name}"
      namespace = var.namespace
    }
    spec = {
      headers = {
        contentSecurityPolicy = var.custom_content_security_policy
      }
    }
  }
}
