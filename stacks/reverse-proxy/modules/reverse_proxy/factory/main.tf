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
variable "external_name" {
  type        = string
  default     = null
  description = "DNS name for ExternalName Service. Mutually exclusive with backend_ip."
}
variable "backend_ip" {
  type        = string
  default     = null
  description = "IP address backend. When set, creates a selector-less Service + EndpointSlice pointing at this IP. Mutually exclusive with external_name — use for hosts that aren't in Technitium (e.g. upstream gateways)."
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
variable "custom_content_security_policy" {
  default = null
  type    = string
}
variable "strip_auth_headers" {
  type    = bool
  default = false
}

# Small-buffer devices: put the lean-proxy hop (../lean_proxy.tf) between
# Traefik and the backend, so the device receives a fixed, short list of
# request headers instead of whatever the browser, Cloudflare and Traefik add
# on the way. lean_proxy.tf explains why the gw router needs this.
variable "header_allowlist" {
  type = object({
    cookies       = list(string)
    extra_headers = optional(list(string), [])
  })
  default     = null
  description = "Small-buffer devices: send the backend only an allowlisted set of request headers, and only these cookies out of Cookie, via the lean-proxy hop. extra_headers adds device-specific request headers to the common list. null = Traefik talks to the backend directly."
  validation {
    # Both lists are written into nginx config and Lua string literals, so
    # anything outside plain token characters is refused rather than escaped.
    condition = var.header_allowlist == null ? true : alltrue(concat(
      [for c in var.header_allowlist.cookies : can(regex("^[A-Za-z0-9._-]+$", c))],
      [for h in var.header_allowlist.extra_headers : can(regex("^[A-Za-z0-9-]+$", h))],
    ))
    error_message = "header_allowlist: cookie names may use only A-Z a-z 0-9 . _ - and header names only A-Z a-z 0-9 -."
  }
}

# The lean-proxy Deployment's pod selector, passed in by the parent as a
# reference to that Deployment. The per-host "<name>-lean" Service selects on
# it, and the Ingress points at that Service, so Terraform creates the Service
# and switches the Ingress only after the Deployment has rolled out.
variable "lean_proxy_selector" {
  type        = map(string)
  default     = null
  description = "Pod selector of the lean-proxy Deployment. Required when header_allowlist is set."
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
  description = "Cloudflare DNS: 'proxied' (CNAME to tunnel), 'non-proxied' (A/AAAA to public IP), 'internal' (A to the internal Traefik LB IP — shadows the * wildcard, resolvable everywhere but routable only from home LANs/WG/VPN; pair with traefik-home-lans-only), or 'none'"
  validation {
    condition     = contains(["proxied", "non-proxied", "internal", "none"], var.dns_type)
    error_message = "dns_type must be 'proxied', 'non-proxied', 'internal', or 'none'."
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
  description = "Override the monitor label. Defaults to the ingress hostname label."
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

# Internal Traefik LB IP used by dns_type = "internal" records — same value
# and caveats as modules/kubernetes/ingress_factory (tracks the dedicated
# MetalLB IP from stacks/traefik, ETP=Local).
variable "internal_lb_ip" {
  type    = string
  default = "10.0.20.203"
}


locals {
  use_backend_ip = var.backend_ip != null
  port_name      = var.backend_protocol == "HTTPS" ? "https-${var.name}" : "${var.name}-web"

  lean = var.header_allowlist != null
  # Request headers the lean hop passes to the device when the client sent
  # them. Host, Cookie (filtered), Connection and the body framing headers are
  # set in the template itself. Accept-Encoding has to stay: the iDRAC answers
  # 404 on /start.html without gzip (measured 2026-09-22). Referer and Origin
  # stay because TP-Link clients send both on every call (tplinkrouterc6u).
  lean_headers = concat([
    "User-Agent", "Accept", "Accept-Encoding", "Accept-Language", "Content-Type",
    "Origin", "Referer", "X-Requested-With", "Cache-Control", "Pragma",
    "If-Modified-Since", "If-None-Match", "If-Match", "If-Unmodified-Since", "If-Range", "Range",
    "Upgrade", "Sec-WebSocket-Key", "Sec-WebSocket-Version", "Sec-WebSocket-Protocol", "Sec-WebSocket-Extensions",
  ], local.lean ? var.header_allowlist.extra_headers : [])
  upstream_url = "${lower(var.backend_protocol)}://${local.use_backend_ip ? var.backend_ip : var.external_name}:${var.port}"
  # Traefik (Go) sends SNI for a DNS name and none for an IP literal; keep that.
  upstream_sni = !local.use_backend_ip && var.backend_protocol == "HTTPS"
}

# ExternalName flavor — used when the backend is addressable by DNS.
resource "kubernetes_service" "proxied-service" {
  count = local.use_backend_ip ? 0 : 1
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
      name        = local.port_name
      port        = var.port
      protocol    = "TCP"
      target_port = var.port
    }
  }
}

# IP-backend flavor — selector-less Service + manually-managed EndpointSlice.
# Used for upstreams that have no DNS entry in Technitium (e.g. 192.168.1.1).
resource "kubernetes_service" "ip-backend-service" {
  count = local.use_backend_ip ? 1 : 0
  metadata {
    name      = var.name
    namespace = var.namespace
    labels = {
      "app" = var.name
    }
  }

  spec {
    type = "ClusterIP"
    port {
      name        = local.port_name
      port        = var.port
      protocol    = "TCP"
      target_port = var.port
    }
  }
}

resource "kubernetes_manifest" "ip_backend_endpointslice" {
  count = local.use_backend_ip ? 1 : 0
  manifest = {
    apiVersion = "discovery.k8s.io/v1"
    kind       = "EndpointSlice"
    metadata = {
      name      = var.name
      namespace = var.namespace
      labels = {
        "kubernetes.io/service-name" = var.name
        "app"                        = var.name
      }
    }
    addressType = "IPv4"
    ports = [{
      name     = local.port_name
      port     = tonumber(var.port)
      protocol = "TCP"
    }]
    endpoints = [{
      addresses = [var.backend_ip]
      conditions = {
        ready = true
      }
    }]
  }
  depends_on = [kubernetes_service.ip-backend-service]
}

# lean-proxy flavor: a per-host Service in front of the shared lean-proxy pods,
# so Traefik's per-service metrics stay per device. The device Service above
# stays in place either way; deleting header_allowlist points the Ingress back
# at it, which is the whole rollback.
resource "kubernetes_service" "lean" {
  count = local.lean ? 1 : 0
  metadata {
    name      = "${var.name}-lean"
    namespace = var.namespace
    labels = {
      "app" = var.name
    }
  }

  spec {
    selector = var.lean_proxy_selector
    port {
      name        = "http"
      port        = 8080
      protocol    = "TCP"
      target_port = 8080
    }
  }

  lifecycle {
    # Orders the rollback. Without it Terraform deletes this Service and the
    # Deployment first and repoints the Ingress last, leaving the host with no
    # backend in between (checked on a terraform_data model of this graph).
    # With it the Ingress goes back to the device Service first.
    create_before_destroy = true
    precondition {
      condition     = var.lean_proxy_selector != null
      error_message = "${var.name}: header_allowlist is set but lean_proxy_selector is not. Pass lean_proxy_selector = one(kubernetes_deployment.lean_proxy[*].spec[0].selector[0].match_labels), and check that this module's lean_proxy_server output is listed in local.lean_servers in lean_proxy.tf."
    }
  }
}

locals {
  # External monitor defaults: on when proxied, off otherwise. Explicit bool overrides.
  effective_external_monitor = var.external_monitor != null ? var.external_monitor : (var.dns_type == "proxied")

  # Emit the annotation when effective is true (positive signal), or when the
  # caller explicitly set external_monitor=false (opt-out). When the caller
  # leaves it null AND dns_type != "proxied", emit nothing — the sync script's
  # default opt-in (any *.viktorbarzin.me ingress) keeps monitoring services
  # that are publicly reachable via routes we don't manage here.
  external_monitor_annotations = local.effective_external_monitor ? merge(
    { "uptime.viktorbarzin.me/external-monitor" = "true" },
    var.external_monitor_name != null ? { "uptime.viktorbarzin.me/external-monitor-name" = var.external_monitor_name } : {},
    ) : (var.external_monitor == false ?
    { "uptime.viktorbarzin.me/external-monitor" = "false" } : {}
  )
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
        var.protected ? "traefik-authentik-forward-auth@kubernetescrd" : null,
        # keep-fallback variant on purpose: forward-auth runs on the line above,
        # so X-Auth-Fallback on this request came from our auth layer, not the
        # client, and blanking it would delete the break-glass marker.
        var.strip_auth_headers ? "traefik-strip-auth-headers-keep-fallback@kubernetescrd" : null,
        var.custom_content_security_policy != null ? "${var.namespace}-custom-csp-${var.name}@kubernetescrd" : null,
      ], var.extra_middlewares)))
      "traefik.ingress.kubernetes.io/router.entrypoints" = "websecure"
      # Through lean-proxy, Traefik speaks plain HTTP to the in-cluster hop and
      # the hop does the device TLS, so these two apply to the direct route only.
      "traefik.ingress.kubernetes.io/service.serversscheme"    = !local.lean && var.backend_protocol == "HTTPS" ? "https" : null
      "traefik.ingress.kubernetes.io/service.serverstransport" = !local.lean && var.backend_protocol == "HTTPS" ? "traefik-insecure-skip-verify@kubernetescrd" : null
      }, var.extra_annotations,
      var.dns_type != "none" ? { "cloudflare.viktorbarzin.me/dns-type" = var.dns_type } : {},
      local.external_monitor_annotations,
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
                # Referencing the lean Service (not just its name) orders this
                # switch after the Service, and through lean_proxy_selector
                # after the Deployment's rollout.
                name = local.lean ? kubernetes_service.lean[0].metadata[0].name : var.name
                port {
                  number = local.lean ? kubernetes_service.lean[0].spec[0].port[0].port : var.port
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
# Proxied hostnames create NO record: they ride the zone-wide * wildcard
# CNAME (ADR-0021, stacks/cloudflared). dns_type = "proxied" still records
# intent and drives the external-monitor annotation. (This factory never
# serves the apex, so unlike modules/kubernetes/ingress_factory there is no
# "@" carve-out.)

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

# 'internal': a publicly-resolvable A record carrying the INTERNAL Traefik LB
# IP. Shadows the * wildcard CNAME (an explicit record wins over the
# wildcard), so the name stays unreachable from outside while home-LAN/WG/VPN
# clients resolve and route to Traefik directly. Mirrors
# modules/kubernetes/ingress_factory's internal_a.
resource "cloudflare_record" "internal_a" {
  count           = var.dns_type == "internal" ? 1 : 0
  name            = var.name
  content         = var.internal_lb_ip
  proxied         = false
  ttl             = 1
  type            = "A"
  zone_id         = var.cloudflare_zone_id
  allow_overwrite = true
}

# This host's server block for the shared lean-proxy config, or null when the
# host goes to its backend directly. lean_proxy.tf joins the non-null ones.
output "lean_proxy_server" {
  value = local.lean ? templatefile("${path.module}/lean_proxy_server.conf.tftpl", {
    host         = "${var.name}.viktorbarzin.me"
    upstream_url = local.upstream_url
    sni          = local.upstream_sni
    cookies      = var.header_allowlist.cookies
    headers      = local.lean_headers
  }) : null
}
