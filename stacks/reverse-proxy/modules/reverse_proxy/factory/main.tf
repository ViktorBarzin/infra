terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

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
variable "strip_auth_headers" {
  type    = bool
  default = false
}
variable "extra_middlewares" {
  type    = list(string)
  default = []
}
variable "skip_global_rate_limit" {
  type    = bool
  default = false
}
variable "dns_type" {
  type        = string
  default     = "none"
  description = "Cloudflare DNS: 'proxied' (CNAME to tunnel), 'non-proxied' (A/AAAA to public IP), or 'none'"
  validation {
    condition     = contains(["proxied", "non-proxied", "none"], var.dns_type)
    error_message = "dns_type must be 'proxied', 'non-proxied', or 'none'."
  }
}
variable "cloudflare_zone_id" {
  type    = string
  default = "fd2c5dd4efe8fe38958944e74d0ced6d"
}
variable "cloudflare_tunnel_id" {
  type    = string
  default = "75182cd7-bb91-4310-b961-5d8967da8b41"
}
variable "public_ip" {
  type    = string
  default = "176.12.22.76"
}
variable "public_ipv6" {
  type    = string
  default = "2001:470:6e:43d::2"
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
      "traefik.ingress.kubernetes.io/router.middlewares" = join(",", compact(concat([
        "traefik-retry@kubernetescrd",
        var.skip_global_rate_limit ? null : "traefik-rate-limit@kubernetescrd",
        var.custom_content_security_policy == null ? "traefik-csp-headers@kubernetescrd" : null,
        "traefik-crowdsec@kubernetescrd",
        var.protected ? "traefik-authentik-forward-auth@kubernetescrd" : null,
        var.strip_auth_headers ? "traefik-strip-auth-headers@kubernetescrd" : null,
        var.rybbit_site_id != null ? "traefik-strip-accept-encoding@kubernetescrd" : null,
        var.rybbit_site_id != null ? "${var.namespace}-rybbit-analytics-${var.name}@kubernetescrd" : null,
        var.custom_content_security_policy != null ? "${var.namespace}-custom-csp-${var.name}@kubernetescrd" : null,
      ], var.extra_middlewares)))
      "traefik.ingress.kubernetes.io/router.entrypoints"       = "websecure"
      "traefik.ingress.kubernetes.io/service.serversscheme"    = var.backend_protocol == "HTTPS" ? "https" : null
      "traefik.ingress.kubernetes.io/service.serverstransport" = var.backend_protocol == "HTTPS" ? "traefik-insecure-skip-verify@kubernetescrd" : null
    }, var.extra_annotations,
      var.dns_type != "none" ? { "cloudflare.viktorbarzin.me/dns-type" = var.dns_type } : {}
    )
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

# Cloudflare DNS records — created automatically when dns_type is set.
resource "cloudflare_record" "proxied" {
  count           = var.dns_type == "proxied" ? 1 : 0
  name            = var.name
  content         = "${var.cloudflare_tunnel_id}.cfargotunnel.com"
  proxied         = true
  ttl             = 1
  type            = "CNAME"
  zone_id         = var.cloudflare_zone_id
  allow_overwrite = true
}

resource "cloudflare_record" "non_proxied_a" {
  count           = var.dns_type == "non-proxied" ? 1 : 0
  name            = var.name
  content         = var.public_ip
  proxied         = false
  ttl             = 1
  type            = "A"
  zone_id         = var.cloudflare_zone_id
  allow_overwrite = true
}

resource "cloudflare_record" "non_proxied_aaaa" {
  count           = var.dns_type == "non-proxied" ? 1 : 0
  name            = var.name
  content         = var.public_ipv6
  proxied         = false
  ttl             = 1
  type            = "AAAA"
  zone_id         = var.cloudflare_zone_id
  allow_overwrite = true
}
