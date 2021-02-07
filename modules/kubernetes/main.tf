variable "tls_secret_name" {}
variable "tls_crt" {}
variable "tls_key" {}
variable "client_certificate_secret_name" {}
variable "hackmd_db_password" {}
variable "mailserver_accounts" {}
variable "mailserver_aliases" {}
variable "pihole_web_password" {}
variable "webhook_handler_secret" {}
variable "wireguard_wg_0_conf" {}
variable "wireguard_wg_0_key" {}
variable "wireguard_firewall_sh" {}
variable "bind_db_viktorbarzin_me" {}
variable "bind_db_viktorbarzin_lan" {}
variable "bind_named_conf_options" {}
variable "alertmanager_account_password" {}

module "blog" {
  source          = "./blog"
  tls_secret_name = var.tls_secret_name
  tls_crt         = var.tls_crt
  tls_key         = var.tls_key
}

module "bind" {
  source              = "./bind"
  db_viktorbarzin_me  = var.bind_db_viktorbarzin_me
  db_viktorbarzin_lan = var.bind_db_viktorbarzin_lan
  named_conf_options  = var.bind_named_conf_options
}

module "dnscrypt" {
  source = "./dnscrypt"
}

module "f1-stream" {
  source          = "./f1-stream"
  tls_secret_name = var.tls_secret_name
  tls_crt         = var.tls_crt
  tls_key         = var.tls_key
}

module "hackmd" {
  source             = "./hackmd"
  hackmd_db_password = var.hackmd_db_password
  tls_secret_name    = var.tls_secret_name
  tls_crt            = var.tls_crt
  tls_key            = var.tls_key
}

# TODO
# module "ingress-nginx" {
#   source = "./ingress-nginx"
# }

module "kms" {
  source          = "./kms"
  tls_secret_name = var.tls_secret_name
  tls_crt         = var.tls_crt
  tls_key         = var.tls_key
}

# TODO
# module "kube-system"{}

module "k8s-dashboard" {
  source                         = "./k8s-dashboard"
  tls_secret_name                = var.tls_secret_name
  tls_crt                        = var.tls_crt
  tls_key                        = var.tls_key
  client_certificate_secret_name = var.client_certificate_secret_name
}

module "mailserver" {
  source                  = "./mailserver"
  mailserver_accounts     = var.mailserver_accounts
  postfix_account_aliases = var.mailserver_aliases
}

module "metallb" {
  source = "./metallb"
}

module monitoring {
  source                        = "./monitoring"
  tls_secret_name               = var.tls_secret_name
  tls_crt                       = var.tls_crt
  tls_key                       = var.tls_key
  alertmanager_account_password = var.alertmanager_account_password
}

module openid_help_page {
  source          = "./openid_help_page"
  tls_secret_name = var.tls_secret_name
  tls_crt         = var.tls_crt
  tls_key         = var.tls_key
}

module pihole {
  source       = "./pihole"
  web_password = var.pihole_web_password

  tls_secret_name = var.tls_secret_name
  tls_crt         = var.tls_crt
  tls_key         = var.tls_key

  depends_on = [module.bind] # DNS goes like pihole -> bind -> dnscrypt
}

module privatebin {
  source          = "./privatebin"
  tls_secret_name = var.tls_secret_name
  tls_crt         = var.tls_crt
  tls_key         = var.tls_key
}

module webhook_handler {
  source          = "./webhook_handler"
  tls_secret_name = var.tls_secret_name
  tls_crt         = var.tls_crt
  tls_key         = var.tls_key
  webhook_secret  = var.webhook_handler_secret
}

module wireguard {
  source          = "./wireguard"
  tls_secret_name = var.tls_secret_name
  tls_crt         = var.tls_crt
  tls_key         = var.tls_key
  wg_0_conf       = var.wireguard_wg_0_conf
  wg_0_key        = var.wireguard_wg_0_key
  firewall_sh     = var.wireguard_firewall_sh
}
