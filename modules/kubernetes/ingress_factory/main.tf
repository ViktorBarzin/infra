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
variable "auth" {
  type        = string
  default     = "required"
  description = <<-EOT
    Auth posture for this ingress. Pick by asking "what gates the app?":

      * "required" (default, fail-closed): Authentik forward-auth gates every
        request. Pick this when the backend has NO built-in user auth and
        Authentik is the only thing standing between strangers and the app.
        Examples: prowlarr, qbittorrent, netbox, phpipam, k8s-dashboard, any
        admin UI shipped without its own login.

      * "app": the backend handles its own user authentication (NextAuth,
        Django sessions, OAuth, bearer-token API, etc.) and Authentik would
        only get in the way. No Authentik middleware is attached; the app's
        own login is the gate. Examples: immich, linkwarden, tandoor,
        freshrss, affine, actualbudget, audiobookshelf, novelapp.
        **Functionally identical to "none"** — the distinct name exists to
        record intent at the call site so future readers don't have to guess.

      * "public": Authentik anonymous binding via the `public` outpost.
        Strangers are auto-bound to the `guest` Authentik user; logged-in
        users keep their identity in X-authentik-username. Only works for
        top-level browser navigation — CORS preflight rejects XHR/fetch and
        automation can't replay the cookie dance. Audit trail, not a gate.

      * "none": no Authentik middleware, no own-auth claim — explicitly
        public or unauthenticated-by-design. Use for: Anubis-fronted content
        sites (where Anubis is the gate), native-client APIs that auth
        themselves (Git, /v2/, WebDAV/CalDAV, CardDAV), webhook receivers,
        OAuth callbacks, and Authentik outposts themselves.

    **Anti-exposure rule** (the reason "app" exists as a distinct mode):
    only pick "app" or "none" AFTER you have verified the app has its own
    user auth (for "app") OR the endpoint is intentionally public (for
    "none"). Picking either of these on a naked admin UI exposes it to the
    internet. The default is "required" specifically so accidental omission
    fails closed.

    **Convention**: when using "app" or "none", add a comment line above
    the `auth = "..."` line stating what gates the app or why it's public.
    Future-you reads the call site, not the module description.
  EOT
  validation {
    condition     = contains(["required", "app", "public", "none"], var.auth)
    error_message = "auth must be one of: required, app, public, none."
  }
}
variable "ingress_path" {
  type    = list(string)
  default = ["/"]
}
variable "max_body_size" {
  type        = string
  default     = null
  description = "Maximum request body size, e.g. '5g'. null = no limit (Traefik default). When set, a per-ingress Buffering middleware is created and attached."
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
  effective_host = var.full_host != null ? var.full_host : "${var.host != null ? var.host : var.name}.${var.root_domain}"
  # Anti-AI default: ON when no Authentik auth fronts the ingress (auth =
  # "none" or auth = "app" — either the app gates users itself or the site
  # is intentionally public). When Authentik gates the request
  # (required/public), the auth flow already discourages bots.
  effective_anti_ai = var.anti_ai_scraping != null ? var.anti_ai_scraping : (var.auth == "none" || var.auth == "app")

  # Auth middleware selection. "app" and "none" both attach no Authentik
  # middleware — "app" signals "the backend has its own user auth", "none"
  # signals "intentionally public / native-client API / webhook". The
  # distinction lives at the call site for human readers; the runtime
  # effect is identical.
  auth_middleware = (
    var.auth == "required" ? "traefik-authentik-forward-auth@kubernetescrd" :
    var.auth == "public" ? "traefik-authentik-forward-auth-public@kubernetescrd" :
    null
  )

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

  # Parse "5g"/"50m"/"1024k"/"42" into bytes. Traefik's Buffering middleware
  # takes maxRequestBodyBytes as an integer. Empty unit = bytes.
  body_size_match = var.max_body_size == null ? null : regex("^([0-9]+)([kmgKMG]?)$", var.max_body_size)
  body_size_unit_multiplier = var.max_body_size == null ? 0 : (
    lower(local.body_size_match[1]) == "g" ? 1073741824 :
    lower(local.body_size_match[1]) == "m" ? 1048576 :
    lower(local.body_size_match[1]) == "k" ? 1024 :
    1
  )
  max_body_size_bytes = var.max_body_size == null ? 0 : tonumber(local.body_size_match[0]) * local.body_size_unit_multiplier
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
        local.effective_anti_ai ? "traefik-ai-bot-block@kubernetescrd" : null,
        local.effective_anti_ai ? "traefik-anti-ai-headers@kubernetescrd" : null,
        local.auth_middleware,
        var.allow_local_access_only ? "traefik-local-only@kubernetescrd" : null,
        var.custom_content_security_policy != null ? "${var.namespace}-custom-csp-${var.name}@kubernetescrd" : null,
        var.max_body_size != null ? "${var.namespace}-buffering-${var.name}@kubernetescrd" : null,
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

# Buffering middleware - created per service when max_body_size is set.
# Traefik default is unlimited; setting maxRequestBodyBytes enforces a limit
# (e.g. Forgejo container pushes can ship multi-GB layer blobs).
resource "kubernetes_manifest" "buffering" {
  count = var.max_body_size != null ? 1 : 0

  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "buffering-${var.name}"
      namespace = var.namespace
    }
    spec = {
      buffering = {
        maxRequestBodyBytes = local.max_body_size_bytes
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
