# Reverse proxy for things in my infra that are 
# outside of K8S but would be nice to use the Nginx-ingress

variable "tls_secret_name" {}

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
  depends_on       = [kubernetes_namespace.reverse-proxy]
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
  source           = "./factory"
  name             = "idrac"
  external_name    = "idrac.viktorbarzin.lan"
  port             = 443
  tls_secret_name  = var.tls_secret_name
  backend_protocol = "HTTPS"
  depends_on       = [kubernetes_namespace.reverse-proxy]
}

# Can either listen on https or http; can't do both :/
# TODO: Not working yet
module "tp-link-gateway" {
  source           = "./factory"
  name             = "gw"
  external_name    = "gw.viktorbarzin.lan"
  port             = 443
  tls_secret_name  = var.tls_secret_name
  backend_protocol = "HTTPS"
  depends_on       = [kubernetes_namespace.reverse-proxy]
}

# https://truenas.viktorbarzin.me/
module "truenas" {
  source          = "./factory"
  name            = "truenas"
  external_name   = "truenas.viktorbarzin.lan"
  port            = 80
  tls_secret_name = var.tls_secret_name
  max_body_size   = "0m"
  depends_on      = [kubernetes_namespace.reverse-proxy]
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

# https://esxi.viktorbarzin.me/
module "esxi" {
  source           = "./factory"
  name             = "esxi"
  external_name    = "esxi.viktorbarzin.lan"
  port             = 443
  tls_secret_name  = var.tls_secret_name
  backend_protocol = "HTTPS"
  max_body_size    = "0" # unlimited
  depends_on       = [kubernetes_namespace.reverse-proxy]
}

# https://valchedrym.viktorbarzin.me/
module "valchedrym" {
  source           = "./factory"
  name             = "valchedrym"
  external_name    = "valchedrym.viktorbarzin.lan"
  port             = 20123
  tls_secret_name  = var.tls_secret_name
  backend_protocol = "HTTP"
  depends_on       = [kubernetes_namespace.reverse-proxy]
}

# https://ip150.viktorbarzin.me/
# Server has funky behaviour based on headers; works on some browrsers not others...
# module "valchedrym-ip150" {
#   source        = "./factory"
#   name          = "ip150"
#   external_name = "valchedrym.ddns.net"
#   # port               = 5081 // HTTPS port; 5080 is HTTP if needed
#   port               = 5080 // HTTPS port; 5080 is HTTP if needed
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

# https://server-switch.viktorbarzin.me/
module "server-switch" {
  source          = "./factory"
  name            = "server-switch"
  external_name   = "server-switch.viktorbarzin.lan"
  port            = 80
  tls_secret_name = var.tls_secret_name
  depends_on      = [kubernetes_namespace.reverse-proxy]
}

# https://ha-sofia.viktorbarzin.me/
module "ha-sofia" {
  source          = "./factory"
  name            = "ha-sofia"
  external_name   = "ha-sofia.viktorbarzin.lan"
  port            = 8123
  tls_secret_name = var.tls_secret_name
  depends_on      = [kubernetes_namespace.reverse-proxy]
}

# https://ha-london.viktorbarzin.me/
module "ha-london" {
  source          = "./factory"
  name            = "ha-london"
  external_name   = "ha-london.viktorbarzin.lan"
  port            = 8123
  tls_secret_name = var.tls_secret_name
  depends_on      = [kubernetes_namespace.reverse-proxy]
}
