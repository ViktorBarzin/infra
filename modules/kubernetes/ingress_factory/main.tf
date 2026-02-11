
variable "name" { type = string }
variable "service_name" {
  type    = string
  default = null # defaults to name
}
variable "host" {
  type    = string
  default = null
}
variable "namespace" { type = string }
variable "external_name" {
  type    = string
  default = null
}
variable "port" {
  default = "80"
}
variable "tls_secret_name" {}
variable "backend_protocol" {
  default = "HTTP"
}
variable "protected" {
  type    = bool
  default = false
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
variable "ssl_redirect" {
  default = true
  type    = bool
}
variable "allow_local_access_only" {
  default = false
  type    = bool
}
variable "root_domain" {
  default = "viktorbarzin.me"
  type    = string
}
variable "rybbit_site_id" {
  default = null
  type    = string
}
variable "custom_content_security_policy" {
  type    = string
  default = null
}
variable "exclude_crowdsec" {
  type    = bool
  default = false
}
variable "full_host" {
  type    = string
  default = null
}
variable "extra_middlewares" {
  type    = list(string)
  default = []
}
variable "skip_default_rate_limit" {
  type    = bool
  default = false
}

locals {
  effective_host = var.full_host != null ? var.full_host : "${var.host != null ? var.host : var.name}.${var.root_domain}"
}


resource "kubernetes_service" "proxied-service" {
  count = var.external_name == null ? 0 : 1
  metadata {
    name      = var.name
    namespace = var.namespace
    labels = {
      "app" = var.name
    }
  }

  spec {
    type          = var.external_name != null ? "ExternalName" : "ClusterIP"
    external_name = var.name

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
      "traefik.ingress.kubernetes.io/router.middlewares" = join(",", compact(concat([
        var.skip_default_rate_limit ? null : "traefik-rate-limit@kubernetescrd",
        var.custom_content_security_policy == null ? "traefik-csp-headers@kubernetescrd" : null,
        var.exclude_crowdsec ? null : "traefik-crowdsec@kubernetescrd",
        var.protected ? "traefik-authentik-forward-auth@kubernetescrd" : null,
        var.allow_local_access_only ? "traefik-local-only@kubernetescrd" : null,
        var.rybbit_site_id != null ? "traefik-strip-accept-encoding@kubernetescrd" : null,
        var.rybbit_site_id != null ? "${var.namespace}-rybbit-analytics-${var.name}@kubernetescrd" : null,
        var.custom_content_security_policy != null ? "${var.namespace}-custom-csp-${var.name}@kubernetescrd" : null,
      ], var.extra_middlewares)))
      "traefik.ingress.kubernetes.io/router.entrypoints" = "websecure"
    }, var.extra_annotations)
  }

  spec {
    ingress_class_name = "traefik"
    tls {
      hosts       = [local.effective_host]
      secret_name = var.tls_secret_name
    }
    rule {
      host = local.effective_host
      http {
        dynamic "path" {
          for_each = var.ingress_path

          content {
            path = path.value
            backend {
              service {

                name = var.service_name != null ? var.service_name : var.name
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

# Rybbit analytics middleware (rewrite-body plugin with content-type filtering) - created per service when rybbit_site_id is set
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
        rewrite-body = {
          rewrites = [{
            regex       = "</head>"
            replacement = "<script src=\"https://rybbit.viktorbarzin.me/api/script.js\" data-site-id=\"${var.rybbit_site_id}\" defer></script></head>"
          }]
          monitoring = {
            types = ["text/html"]
          }
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
