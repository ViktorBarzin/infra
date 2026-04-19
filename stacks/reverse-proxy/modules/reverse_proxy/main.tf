# Reverse proxy for things in my infra that are 
# outside of K8S but would be nice to use the Nginx-ingress

variable "tls_secret_name" {}
variable "pfsense_homepage_token" {}
variable "haos_homepage_token" {
  type      = string
  default   = ""
  sensitive = true
}

resource "kubernetes_namespace" "reverse-proxy" {
  metadata {
    name = "reverse-proxy"
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../../../modules/kubernetes/setup_tls_secret"
  namespace       = "reverse-proxy"
  tls_secret_name = var.tls_secret_name
  depends_on      = [kubernetes_namespace.reverse-proxy]
}

# https://pfsense.viktorbarzin.me/
module "pfsense" {
  source           = "./factory"
  dns_type         = "proxied"
  name             = "pfsense"
  external_name    = "pfsense.viktorbarzin.lan"
  tls_secret_name  = var.tls_secret_name
  port             = 443
  backend_protocol = "HTTPS"

  extra_annotations = {
    "gethomepage.dev/enabled" : "true"
    "gethomepage.dev/description" : "Cluster Firewall"
    "gethomepage.dev/group" : "Identity & Security"
    "gethomepage.dev/icon" : "pfsense.png"
    "gethomepage.dev/name" : "pFsense"
    "gethomepage.dev/widget.type" : "pfsense"
    "gethomepage.dev/widget.version" : "2"
    "gethomepage.dev/widget.url" : "https://10.0.20.1"
    "gethomepage.dev/widget.username" : "admin"
    "gethomepage.dev/widget.password" : var.pfsense_homepage_token
    "gethomepage.dev/widget.fields" = "[\"load\", \"memory\", \"temp\", \"disk\"]"
    "gethomepage.dev/widget.wan"    = "vtnet0"
  }
  depends_on = [kubernetes_namespace.reverse-proxy]
}

# https://nas.viktorbarzin.me/
module "nas" {
  source           = "./factory"
  dns_type         = "proxied"
  name             = "nas"
  external_name    = "nas.viktorbarzin.lan"
  port             = 5001
  tls_secret_name  = var.tls_secret_name
  backend_protocol = "HTTPS"
  max_body_size    = "0m"
  depends_on       = [kubernetes_namespace.reverse-proxy]
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Synology NAS"
    "gethomepage.dev/description"  = "Network storage"
    "gethomepage.dev/icon"         = "synology.png"
    "gethomepage.dev/group"        = "Infrastructure"
    "gethomepage.dev/pod-selector" = ""
  }
}

# https://files.viktorbarzin.me/
module "nas-files" {
  source            = "./factory"
  dns_type          = "non-proxied"
  name              = "files"
  external_name     = "nas.viktorbarzin.lan"
  port              = 5001
  tls_secret_name   = var.tls_secret_name
  backend_protocol  = "HTTPS"
  protected         = false # allow anyone to download files
  ingress_path      = ["/sharing", "/scripts", "/webman", "/wfmlogindialog.js", "/fsdownload"]
  max_body_size     = "0m"
  depends_on        = [kubernetes_namespace.reverse-proxy]
  extra_annotations = { "gethomepage.dev/enabled" = "false" }
}

# https://idrac.viktorbarzin.me/
module "idrac" {
  source             = "./factory"
  dns_type           = "proxied"
  name               = "idrac"
  external_name      = "idrac.viktorbarzin.lan"
  port               = 443
  tls_secret_name    = var.tls_secret_name
  backend_protocol   = "HTTPS"
  strip_auth_headers = true
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "iDRAC"
    "gethomepage.dev/description"  = "Server management"
    "gethomepage.dev/icon"         = "dell.png"
    "gethomepage.dev/group"        = "Infrastructure"
    "gethomepage.dev/pod-selector" = ""
  }
  depends_on = [kubernetes_namespace.reverse-proxy]
}

module "tp-link-gateway" {
  source             = "./factory"
  dns_type           = "proxied"
  name               = "gw"
  backend_ip         = "192.168.1.1"
  port               = 443
  tls_secret_name    = var.tls_secret_name
  backend_protocol   = "HTTPS"
  depends_on         = [kubernetes_namespace.reverse-proxy]
  protected          = true
  strip_auth_headers = true
  extra_annotations  = { "gethomepage.dev/enabled" = "false" }
}

# https://proxmox.viktorbarzin.me/
module "proxmox" {
  source           = "./factory"
  dns_type         = "proxied"
  name             = "proxmox"
  external_name    = "proxmox.viktorbarzin.lan"
  port             = 8006
  tls_secret_name  = var.tls_secret_name
  backend_protocol = "HTTPS"
  max_body_size    = "0" # unlimited
  depends_on       = [kubernetes_namespace.reverse-proxy]
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Proxmox"
    "gethomepage.dev/description"  = "Hypervisor"
    "gethomepage.dev/icon"         = "proxmox.png"
    "gethomepage.dev/group"        = "Infrastructure"
    "gethomepage.dev/pod-selector" = ""
  }
}

# https://docker.viktorbarzin.me/ (registry web UI)
module "docker-registry-ui" {
  source          = "./factory"
  dns_type        = "proxied"
  name            = "docker"
  external_name   = "docker-registry.viktorbarzin.lan"
  port            = 8080
  tls_secret_name = var.tls_secret_name
  depends_on      = [kubernetes_namespace.reverse-proxy]
  extra_annotations = {
    # Override middleware chain to remove rate-limit; the UI fires many API calls to list repos/tags
    "traefik.ingress.kubernetes.io/router.middlewares" = "traefik-csp-headers@kubernetescrd,traefik-crowdsec@kubernetescrd,traefik-authentik-forward-auth@kubernetescrd"
    "gethomepage.dev/enabled"                          = "true"
    "gethomepage.dev/name"                             = "Docker Registry"
    "gethomepage.dev/description"                      = "Container registry"
    "gethomepage.dev/icon"                             = "docker.png"
    "gethomepage.dev/group"                            = "Infrastructure"
    "gethomepage.dev/pod-selector"                     = ""
  }
}

# https://registry.viktorbarzin.me/ (Docker CLI push/pull endpoint)
module "docker-registry-cli" {
  source           = "./factory"
  dns_type         = "non-proxied"
  name             = "registry"
  external_name    = "docker-registry.viktorbarzin.lan"
  port             = 5050
  backend_protocol = "HTTPS"
  tls_secret_name  = var.tls_secret_name
  protected        = false # Docker CLI uses htpasswd, NOT Authentik
  max_body_size    = "0"   # unlimited - Docker layers can be large
  depends_on       = [kubernetes_namespace.reverse-proxy]
  extra_annotations = {
    # Skip rate-limit (Docker push/pull generates many rapid requests)
    # Keep CrowdSec for L7 protection
    "traefik.ingress.kubernetes.io/router.middlewares" = "traefik-csp-headers@kubernetescrd,traefik-crowdsec@kubernetescrd"
    "gethomepage.dev/enabled"                          = "false"
  }
}

# https://valchedrym.viktorbarzin.me/
module "valchedrym" {
  source            = "./factory"
  dns_type          = "proxied"
  name              = "valchedrym"
  external_name     = "valchedrym.viktorbarzin.lan"
  tls_secret_name   = var.tls_secret_name
  port              = 80
  backend_protocol  = "HTTP"
  depends_on        = [kubernetes_namespace.reverse-proxy]
  extra_annotations = { "gethomepage.dev/enabled" = "false" }
}

# https://ip150.viktorbarzin.me/
# Server has funky behaviour based on headers; works on some browrsers not others...
# module "valchedrym-ip150" {
#   source = "./factory"
#   name   = "ip150"
#   # external_name = "valchedrym.ddns.net"
#   external_name      = "192.168.0.10"
#   port               = 80
#   backend_protocol   = "HTTP"
#   use_proxy_protocol = false
#   tls_secret_name    = var.tls_secret_name
#   protected          = false
#   depends_on         = [kubernetes_namespace.reverse-proxy]
# }

# https://mladost3.viktorbarzin.me/
module "mladost3" {
  source            = "./factory"
  name              = "mladost3"
  external_name     = "mladost3.ddns.net"
  port              = 8080
  tls_secret_name   = var.tls_secret_name
  depends_on        = [kubernetes_namespace.reverse-proxy]
  external_monitor  = false
  extra_annotations = { "gethomepage.dev/enabled" = "false" }
}

# # https://server-switch.viktorbarzin.me/
# module "server-switch" {
#   source          = "./factory"
#   name            = "server-switch"
#   external_name   = "server-switch.viktorbarzin.lan"
#   port            = 80
#   tls_secret_name = var.tls_secret_name
#   depends_on      = [kubernetes_namespace.reverse-proxy]
# }

# https://ha-sofia.viktorbarzin.me/
resource "kubernetes_manifest" "ha_sofia_rate_limit" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "ha-sofia-rate-limit"
      namespace = "reverse-proxy"
    }
    spec = {
      rateLimit = {
        average = 100
        burst   = 200
      }
    }
  }
}

# Per-service retry — bumps default (attempts=2) to 3 so transient DNS/connect
# stalls on the ha-sofia.viktorbarzin.lan ExternalName are absorbed before
# surfacing a 502. Drives bd code-rd1 Phase 2.2.
resource "kubernetes_manifest" "ha_sofia_retry" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "ha-sofia-retry"
      namespace = "reverse-proxy"
    }
    spec = {
      retry = {
        attempts        = 3
        initialInterval = "100ms"
      }
    }
  }
}

# Per-service ServersTransport — overrides the global 60s dialTimeout
# (set for Immich) with 500ms so a stall fails fast and the retry middleware
# kicks in instead of blocking the connection for seconds. Drives bd
# code-rd1 Phase 2.3.
resource "kubernetes_manifest" "ha_sofia_transport" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "ServersTransport"
    metadata = {
      name      = "ha-sofia-transport"
      namespace = "reverse-proxy"
    }
    spec = {
      forwardingTimeouts = {
        dialTimeout           = "500ms"
        responseHeaderTimeout = "30s"
        idleConnTimeout       = "90s"
      }
    }
  }
}

module "ha-sofia" {
  source          = "./factory"
  dns_type        = "non-proxied"
  name            = "ha-sofia"
  external_name   = "ha-sofia.viktorbarzin.lan"
  port            = 8123
  tls_secret_name = var.tls_secret_name
  # depends_on on the retry/transport manifests avoids a dangling-reference
  # window that would 404 ha-sofia traffic (memory 768: 2026-04-17 P0 outage).
  depends_on = [
    kubernetes_namespace.reverse-proxy,
    kubernetes_manifest.ha_sofia_retry,
    kubernetes_manifest.ha_sofia_transport,
  ]
  protected              = false
  skip_global_rate_limit = true
  extra_middlewares = [
    "reverse-proxy-ha-sofia-rate-limit@kubernetescrd",
    "reverse-proxy-ha-sofia-retry@kubernetescrd",
  ]
  extra_annotations = {
    "gethomepage.dev/enabled"                                = "true"
    "gethomepage.dev/name"                                   = "Home Assistant Sofia"
    "gethomepage.dev/description"                            = "Smart home hub"
    "gethomepage.dev/icon"                                   = "home-assistant.png"
    "gethomepage.dev/group"                                  = "Smart Home"
    "gethomepage.dev/pod-selector"                           = ""
    "traefik.ingress.kubernetes.io/service.serverstransport" = "reverse-proxy-ha-sofia-transport@kubernetescrd"
  }
}

# https://music-assistant.viktorbarzin.me/
module "music-assistant" {
  source          = "./factory"
  dns_type        = "non-proxied"
  name            = "music-assistant"
  external_name   = "ha-sofia.viktorbarzin.lan"
  port            = 8095
  tls_secret_name = var.tls_secret_name
  depends_on = [
    kubernetes_namespace.reverse-proxy,
    kubernetes_manifest.ha_sofia_retry,
    kubernetes_manifest.ha_sofia_transport,
  ]
  protected              = false
  skip_global_rate_limit = true
  extra_middlewares = [
    "reverse-proxy-ha-sofia-rate-limit@kubernetescrd",
    "reverse-proxy-ha-sofia-retry@kubernetescrd",
  ]
  extra_annotations = {
    "traefik.ingress.kubernetes.io/service.serverstransport" = "reverse-proxy-ha-sofia-transport@kubernetescrd"
  }
}

# https://ha-london.viktorbarzin.me/
module "ha-london" {
  source          = "./factory"
  dns_type        = "non-proxied"
  name            = "ha-london"
  external_name   = "ha-london.viktorbarzin.lan"
  port            = 8123
  tls_secret_name = var.tls_secret_name
  depends_on      = [kubernetes_namespace.reverse-proxy]
  protected       = false
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Home Assistant London"
    "gethomepage.dev/description"  = "Smart home hub"
    "gethomepage.dev/icon"         = "home-assistant.png"
    "gethomepage.dev/group"        = "Smart Home"
    "gethomepage.dev/pod-selector" = ""
  }
}

# https://london.viktorbarzin.me/
module "london" {
  source           = "./factory"
  dns_type         = "proxied"
  name             = "london"
  external_name    = "openwrt-london.viktorbarzin.lan"
  port             = 443
  tls_secret_name  = var.tls_secret_name
  backend_protocol = "HTTPS"
  protected        = true
  depends_on       = [kubernetes_namespace.reverse-proxy]
  extra_annotations = {
    "gethomepage.dev/enabled" : "false"
    "gethomepage.dev/description" : "OpenWRT London"
    # gethomepage.dev/group: Media
    "gethomepage.dev/icon" : "openwrt.png"
    "gethomepage.dev/name" : "OpenWRT London"
    "gethomepage.dev/widget.type" : "openwrt"
    "gethomepage.dev/widget.url" : "https://100.64.0.14"
    # "gethomepage.dev/widget.token"    = var.homepage_token
    "gethomepage.dev/widget.username" : "homepage"
    "gethomepage.dev/widget.password" : "" # add later as Flint2's openwrt is a little odd
    "gethomepage.dev/pod-selector" : ""
  }
}
module "pi-lights" {
  source            = "./factory"
  dns_type          = "proxied"
  name              = "pi"
  external_name     = "ha-london.viktorbarzin.lan"
  port              = 5000
  tls_secret_name   = var.tls_secret_name
  protected         = true
  depends_on        = [kubernetes_namespace.reverse-proxy]
  extra_annotations = { "gethomepage.dev/enabled" = "false" }
}

# module "ups" { # .NET app doesn't work well behind host
#   source           = "./factory"
#   name             = "ups"
#   external_name    = "ups.viktorbarzin.lan"
#   backend_protocol = "HTTPS"
#   port             = 443
#   tls_secret_name  = var.tls_secret_name
#   # protected        = true
#   protected  = false
#   depends_on = [kubernetes_namespace.reverse-proxy]
#   extra_annotations = {
#     "nginx.ingress.kubernetes.io/upstream-vhost" : "",
#     # "nginx.ingress.kubernetes.io/proxy-set-header" : "Host: <>",
#   }
# }

module "mbp14" {
  source            = "./factory"
  dns_type          = "proxied"
  name              = "mbp14"
  external_name     = "mbp14.viktorbarzin.lan"
  port              = 4020
  tls_secret_name   = var.tls_secret_name
  protected         = true
  depends_on        = [kubernetes_namespace.reverse-proxy]
  extra_annotations = { "gethomepage.dev/enabled" = "false" }
}
