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
variable "anti_ai_scraping" {
  type    = bool
  default = null # null = auto (enabled when not protected, disabled when protected)
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

# Uptime Kuma external monitor: when true, annotate the ingress so the
# external-monitor-sync CronJob creates a `[External] <name>` monitor pointing
# at https://<host>. Null means "follow dns_type" — enabled when proxied.
variable "external_monitor" {
  type        = bool
  default     = null
  description = "Enable Uptime Kuma external monitor. null = auto (enabled when dns_type == 'proxied')."
}

variable "external_monitor_name" {
  type        = string
  default     = null
  description = "Override the monitor label. Defaults to the ingress hostname label (e.g. 'dawarich' for dawarich.viktorbarzin.me)."
}

# Cloudflare config defaults — override via variables if these change.
# Source of truth: config.tfvars (cloudflare_zone_id, cloudflare_tunnel_id, public_ip, public_ipv6)
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

variable "homepage_group" {
  type    = string
  default = null # auto-detect from namespace
}

variable "homepage_enabled" {
  type    = bool
  default = true
}

locals {
  effective_host    = var.full_host != null ? var.full_host : "${var.host != null ? var.host : var.name}.${var.root_domain}"
  effective_anti_ai = var.anti_ai_scraping != null ? var.anti_ai_scraping : !var.protected

  # External monitor enabled by default when the ingress has a public DNS
  # record (either CF-proxied or direct A/AAAA). Explicit bool overrides.
  effective_external_monitor = var.external_monitor != null ? var.external_monitor : (var.dns_type != "none")

  # Emit the annotation when effective is true (positive signal), or when the
  # caller explicitly set external_monitor=false (opt-out). When the caller
  # leaves it null AND dns_type="none", emit nothing — the sync script's
  # default opt-in (any *.viktorbarzin.me ingress) keeps monitoring services
  # that are publicly reachable via routes we don't manage here (e.g.
  # helm-provisioned ingresses, services behind cloudflared tunnel with DNS
  # set elsewhere).
  external_monitor_annotations = local.effective_external_monitor ? merge(
    { "uptime.viktorbarzin.me/external-monitor" = "true" },
    var.external_monitor_name != null ? { "uptime.viktorbarzin.me/external-monitor-name" = var.external_monitor_name } : {},
    ) : (var.external_monitor == false ?
    { "uptime.viktorbarzin.me/external-monitor" = "false" } : {}
  )

  ns_to_group = {
    monitoring      = "Infrastructure"
    prometheus      = "Infrastructure"
    technitium      = "Infrastructure"
    traefik         = "Infrastructure"
    metallb-system  = "Infrastructure"
    kyverno         = "Infrastructure"
    authentik       = "Identity & Security"
    crowdsec        = "Identity & Security"
    woodpecker      = "Development & CI"
    forgejo         = "Development & CI"
    immich          = "Media & Entertainment"
    frigate         = "Smart Home"
    home-assistant  = "Smart Home"
    ollama          = "AI & Data"
    dbaas           = "Infrastructure"
    servarr         = "Media & Entertainment"
    navidrome       = "Media & Entertainment"
    nextcloud       = "Productivity"
    n8n             = "Automation"
    changedetection = "Automation"
    finance         = "Finance & Personal"
    homepage        = "Core Platform"
    reverse-proxy   = "Smart Home"
    mailserver      = "Infrastructure"
  }

  homepage_group = coalesce(
    var.homepage_group,
    lookup(local.ns_to_group, var.namespace, "Other")
  )

  dns_name = local.effective_host == var.root_domain ? "@" : replace(local.effective_host, ".${var.root_domain}", "")

  homepage_defaults = var.homepage_enabled ? {
    "gethomepage.dev/enabled" = "true"
    "gethomepage.dev/name"    = replace(replace(var.name, "-", " "), "_", " ")
    "gethomepage.dev/group"   = local.homepage_group
    "gethomepage.dev/href"    = "https://${local.effective_host}"
    "gethomepage.dev/icon"    = "${replace(var.name, "-", "")}.png"
  } : {}
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
        "traefik-retry@kubernetescrd",
        "traefik-error-pages@kubernetescrd",
        var.skip_default_rate_limit ? null : "traefik-rate-limit@kubernetescrd",
        var.custom_content_security_policy == null ? "traefik-csp-headers@kubernetescrd" : null,
        var.exclude_crowdsec ? null : "traefik-crowdsec@kubernetescrd",
        local.effective_anti_ai ? "traefik-ai-bot-block@kubernetescrd" : null,
        local.effective_anti_ai ? "traefik-anti-ai-headers@kubernetescrd" : null,
        var.protected ? "traefik-authentik-forward-auth@kubernetescrd" : null,
        var.allow_local_access_only ? "traefik-local-only@kubernetescrd" : null,
        var.custom_content_security_policy != null ? "${var.namespace}-custom-csp-${var.name}@kubernetescrd" : null,
      ], var.extra_middlewares)))
      "traefik.ingress.kubernetes.io/router.entrypoints" = "websecure"
      }, local.homepage_defaults, var.extra_annotations,
      var.dns_type != "none" ? { "cloudflare.viktorbarzin.me/dns-type" = var.dns_type } : {},
      local.external_monitor_annotations,
    )
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
# Proxied: CNAME to Cloudflare tunnel. Non-proxied: A + AAAA to public IP.
resource "cloudflare_record" "proxied" {
  count           = var.dns_type == "proxied" ? 1 : 0
  name            = local.dns_name
  content         = "${var.cloudflare_tunnel_id}.cfargotunnel.com"
  proxied         = true
  ttl             = 1
  type            = "CNAME"
  zone_id         = var.cloudflare_zone_id
  allow_overwrite = true
}

resource "cloudflare_record" "non_proxied_a" {
  count           = var.dns_type == "non-proxied" ? 1 : 0
  name            = local.dns_name
  content         = var.public_ip
  proxied         = false
  ttl             = 1
  type            = "A"
  zone_id         = var.cloudflare_zone_id
  allow_overwrite = true
}

resource "cloudflare_record" "non_proxied_aaaa" {
  count           = var.dns_type == "non-proxied" ? 1 : 0
  name            = local.dns_name
  content         = var.public_ipv6
  proxied         = false
  ttl             = 1
  type            = "AAAA"
  zone_id         = var.cloudflare_zone_id
  allow_overwrite = true
}
