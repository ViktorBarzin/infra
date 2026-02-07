# Reverse proxy for things in my infra that are 
# outside of K8S but would be nice to use the Nginx-ingress

variable "tls_secret_name" {}
variable "truenas_homepage_token" {}
variable "pfsense_homepage_token" {}

resource "kubernetes_namespace" "reverse-proxy" {
  metadata {
    name = "reverse-proxy"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "reverse-proxy"
  tls_secret_name = var.tls_secret_name
  depends_on      = [kubernetes_namespace.reverse-proxy]
}

# https://pfsense.viktorbarzin.me/
module "pfsense" {
  source           = "./factory"
  name             = "pfsense"
  external_name    = "pfsense.viktorbarzin.lan"
  tls_secret_name  = var.tls_secret_name
  port             = 443
  backend_protocol = "HTTPS"

  extra_annotations = {
    "gethomepage.dev/enabled" : "true"
    "gethomepage.dev/description" : "Cluster Firewall"
    # gethomepage.dev/group: Media
    "gethomepage.dev/icon" : "pfsense.png"
    "gethomepage.dev/name" : "pFsense"
    "gethomepage.dev/widget.type" : "pfsense"
    "gethomepage.dev/widget.version" : "2"
    "gethomepage.dev/widget.url" : "https://10.0.20.1"
    # "gethomepage.dev/widget.token"    = var.homepage_token
    "gethomepage.dev/widget.username" : "admin"
    "gethomepage.dev/widget.password" : var.pfsense_homepage_token
    "gethomepage.dev/widget.fields" = "[\"load\", \"memory\", \"wanStatus\", \"disk\"]"
    "gethomepage.dev/widget.wan"    = "vmx0"
    # "gethomepage.dev/pod-selector" : ""
  }
  depends_on     = [kubernetes_namespace.reverse-proxy]
  rybbit_site_id = "b029580e5a7c"
}

# https://nas.viktorbarzin.me/
module "nas" {
  source           = "./factory"
  name             = "nas"
  external_name    = "nas.viktorbarzin.lan"
  port             = 5001
  tls_secret_name  = var.tls_secret_name
  backend_protocol = "HTTPS"
  max_body_size    = "0m"
  depends_on       = [kubernetes_namespace.reverse-proxy]
  rybbit_site_id   = "1e11f8449f7d"
}

# https://files.viktorbarzin.me/
module "nas-files" {
  source           = "./factory"
  name             = "files"
  external_name    = "nas.viktorbarzin.lan"
  port             = 5001
  tls_secret_name  = var.tls_secret_name
  backend_protocol = "HTTPS"
  protected        = false # allow anyone to download files
  ingress_path     = ["/sharing", "/scripts", "/webman", "/wfmlogindialog.js", "/fsdownload"]
  max_body_size    = "0m"
  depends_on       = [kubernetes_namespace.reverse-proxy]
}

# https://idrac.viktorbarzin.me/
module "idrac" {
  source             = "./factory"
  name               = "idrac"
  external_name      = "idrac.viktorbarzin.lan"
  port               = 443
  tls_secret_name    = var.tls_secret_name
  backend_protocol   = "HTTPS"
  strip_auth_headers = true
  extra_annotations  = {}
  depends_on         = [kubernetes_namespace.reverse-proxy]
}

# Can either listen on https or http; can't do both :/
# TODO: Not working yet
module "tp-link-gateway" {
  source             = "./factory"
  name               = "gw"
  external_name      = "gw.viktorbarzin.lan"
  port               = 443
  tls_secret_name    = var.tls_secret_name
  backend_protocol   = "HTTPS"
  depends_on         = [kubernetes_namespace.reverse-proxy]
  protected          = true
  strip_auth_headers = true
  extra_annotations  = {}
}

# https://truenas.viktorbarzin.me/
module "truenas" {
  source          = "./factory"
  name            = "truenas"
  external_name   = "truenas.viktorbarzin.lan"
  port            = 80
  tls_secret_name = var.tls_secret_name
  max_body_size   = "0m"

  extra_annotations = {
    "gethomepage.dev/enabled" : "true"
    "gethomepage.dev/description" : "TrueNAS"
    # gethomepage.dev/group: Media
    "gethomepage.dev/icon" : "truenas.png"
    "gethomepage.dev/name" : "TrueNAS"
    "gethomepage.dev/widget.type" : "truenas"
    "gethomepage.dev/widget.url" : "https://truenas.viktorbarzin.lan"
    "gethomepage.dev/widget.key" : var.truenas_homepage_token
    # "gethomepage.dev/widget.enablePools" : "true"
    # "gethomepage.dev/pod-selector" : ""
  }
  depends_on     = [kubernetes_namespace.reverse-proxy]
  rybbit_site_id = "b66fbd3cb58a"
}

# https://r730.viktorbarzin.me/
module "r730" {
  source           = "./factory"
  name             = "r730"
  external_name    = "r730.viktorbarzin.lan"
  port             = 443
  tls_secret_name  = var.tls_secret_name
  backend_protocol = "HTTPS"
  depends_on       = [kubernetes_namespace.reverse-proxy]
}

# https://proxmox.viktorbarzin.me/
module "proxmox" {
  source           = "./factory"
  name             = "proxmox"
  external_name    = "proxmox.viktorbarzin.lan"
  port             = 8006
  tls_secret_name  = var.tls_secret_name
  backend_protocol = "HTTPS"
  max_body_size    = "0" # unlimited
  depends_on       = [kubernetes_namespace.reverse-proxy]
  rybbit_site_id   = "190a7ad3e1c7"
}

# https://registry.viktorbarzin.me/
module "docker-registry-ui" {
  source          = "./factory"
  name            = "registry"
  external_name   = "docker-registry.viktorbarzin.lan"
  port            = 8080
  tls_secret_name = var.tls_secret_name
  depends_on      = [kubernetes_namespace.reverse-proxy]
  extra_annotations = {
    # Override middleware chain to remove rate-limit; the UI fires many API calls to list repos/tags
    "traefik.ingress.kubernetes.io/router.middlewares" = "traefik-csp-headers@kubernetescrd,traefik-crowdsec@kubernetescrd,traefik-authentik-forward-auth@kubernetescrd"
  }
}

# https://valchedrym.viktorbarzin.me/
module "valchedrym" {
  source           = "./factory"
  name             = "valchedrym"
  external_name    = "valchedrym.viktorbarzin.lan"
  tls_secret_name  = var.tls_secret_name
  port             = 80
  backend_protocol = "HTTP"
  depends_on       = [kubernetes_namespace.reverse-proxy]
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
  source          = "./factory"
  name            = "mladost3"
  external_name   = "mladost3.ddns.net"
  port            = 8080
  tls_secret_name = var.tls_secret_name
  depends_on      = [kubernetes_namespace.reverse-proxy]
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
module "ha-sofia" {
  source          = "./factory"
  name            = "ha-sofia"
  external_name   = "ha-sofia.viktorbarzin.lan"
  port            = 8123
  tls_secret_name = var.tls_secret_name
  depends_on      = [kubernetes_namespace.reverse-proxy]
  protected       = false
  rybbit_site_id  = "590fc392690a"
}

# https://ha-london.viktorbarzin.me/
module "ha-london" {
  source          = "./factory"
  name            = "ha-london"
  external_name   = "ha-london.viktorbarzin.lan"
  port            = 8123
  tls_secret_name = var.tls_secret_name
  depends_on      = [kubernetes_namespace.reverse-proxy]
  protected       = false
}

# https://london.viktorbarzin.me/
module "london" {
  source           = "./factory"
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
  source          = "./factory"
  name            = "pi"
  external_name   = "ha-london.viktorbarzin.lan"
  port            = 5000
  tls_secret_name = var.tls_secret_name
  protected       = true
  depends_on      = [kubernetes_namespace.reverse-proxy]
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
