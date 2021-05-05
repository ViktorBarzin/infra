variable "prod" {}
variable "tls_secret_name" {}
variable "client_certificate_secret_name" {}
variable "hackmd_db_password" {}
variable "mailserver_accounts" {}
variable "mailserver_aliases" {}
variable "mailserver_opendkim_key" {}
variable "pihole_web_password" {}
variable "webhook_handler_secret" {}
variable "wireguard_wg_0_conf" {}
variable "wireguard_wg_0_key" {}
variable "wireguard_firewall_sh" {}
variable "bind_db_viktorbarzin_me" {}
variable "bind_db_viktorbarzin_lan" {}
variable "bind_named_conf_options" {}
variable "alertmanager_account_password" {}
variable "dbaas_root_password" {}
variable "drone_github_client_id" {}
variable "drone_github_client_secret" {}
variable "drone_rpc_secret" {}
# variable "dockerhub_password" {}
variable "oauth_client_id" {}
variable "oauth_client_secret" {}
variable "url_shortener_geolite_license_key" {}
variable "url_shortener_api_key" {}
variable "url_shortener_mysql_password" {}
variable "webhook_handler_fb_verify_token" {}
variable "webhook_handler_fb_page_token" {}
variable "webhook_handler_fb_app_secret" {}
variable "webhook_handler_git_user" {}
variable "webhook_handler_git_token" {}
variable "webhook_handler_ssh_key" {}
variable "idrac_username" {}
variable "idrac_password" {}

resource "null_resource" "core_services" {
  # List all the core modules that must be provisioned first
  depends_on = [module.metallb, module.bind, module.dnscrypt, module.pihole]
}

module "blog" {
  source          = "./blog"
  tls_secret_name = var.tls_secret_name
  # dockerhub_password = var.dockerhub_password

  depends_on = [null_resource.core_services]
}

module "bind" {
  source              = "./bind"
  db_viktorbarzin_me  = var.bind_db_viktorbarzin_me
  db_viktorbarzin_lan = var.bind_db_viktorbarzin_lan
  named_conf_options  = var.bind_named_conf_options
}

module "dbaas" {
  source              = "./dbaas"
  prod                = var.prod
  tls_secret_name     = var.tls_secret_name
  dbaas_root_password = var.dbaas_root_password
}

module "descheduler" {
  source = "./descheduler"
}

module "dnscrypt" {
  source = "./dnscrypt"
}

# CI/CD
module "drone" {
  source          = "./drone"
  tls_secret_name = var.tls_secret_name

  github_client_id     = var.drone_github_client_id
  github_client_secret = var.drone_github_client_secret
  rpc_secret           = var.drone_rpc_secret
  server_host          = "drone.viktorbarzin.me"
  server_proto         = "https"

  depends_on = [null_resource.core_services]
}

module "f1-stream" {
  source          = "./f1-stream"
  tls_secret_name = var.tls_secret_name

  depends_on = [null_resource.core_services]
}

module "hackmd" {
  source             = "./hackmd"
  hackmd_db_password = var.hackmd_db_password
  tls_secret_name    = var.tls_secret_name

  depends_on = [null_resource.core_services]
}

# TODO
# module "ingress-nginx" {
#   source = "./ingress-nginx"
# }

module "kafka" {
  source                         = "./kafka"
  client_certificate_secret_name = var.client_certificate_secret_name
  tls_secret_name                = var.tls_secret_name
}

module "kms" {
  source          = "./kms"
  tls_secret_name = var.tls_secret_name

  depends_on = [null_resource.core_services]
}

module "k8s-dashboard" {
  source                         = "./k8s-dashboard"
  tls_secret_name                = var.tls_secret_name
  client_certificate_secret_name = var.client_certificate_secret_name

  depends_on = [null_resource.core_services]
}

module "mailserver" {
  source                  = "./mailserver"
  tls_secret_name         = var.tls_secret_name
  mailserver_accounts     = var.mailserver_accounts
  postfix_account_aliases = var.mailserver_aliases
  opendkim_key            = var.mailserver_opendkim_key

  depends_on = [null_resource.core_services]
}

module "metallb" {
  source = "./metallb"
}

module "monitoring" {
  source                        = "./monitoring"
  tls_secret_name               = var.tls_secret_name
  alertmanager_account_password = var.alertmanager_account_password
  idrac_username                = var.idrac_username
  idrac_password                = var.idrac_password

  depends_on = [null_resource.core_services]
}

module "oauth" {
  source          = "./oauth-proxy"
  tls_secret_name = var.tls_secret_name
  client_id       = var.oauth_client_id
  client_secret   = var.oauth_client_secret

  depends_on = [null_resource.core_services]
}

module "openid_help_page" {
  source          = "./openid_help_page"
  tls_secret_name = var.tls_secret_name

  depends_on = [null_resource.core_services]
}

module "pihole" {
  source       = "./pihole"
  web_password = var.pihole_web_password

  tls_secret_name = var.tls_secret_name

  depends_on = [module.bind] # DNS goes like pihole -> bind -> dnscrypt
}

module "privatebin" {
  source          = "./privatebin"
  tls_secret_name = var.tls_secret_name

  depends_on = [null_resource.core_services]
}

# module "vault" {
#   source          = "./vault"
#   tls_secret_name = var.tls_secret_name
# }

module "reloader" {
  source = "./reloader"
}

module "url" {
  source              = "./url-shortener"
  tls_secret_name     = var.tls_secret_name
  geolite_license_key = var.url_shortener_geolite_license_key
  api_key             = var.url_shortener_api_key
  mysql_password      = var.url_shortener_mysql_password
}

module "webhook_handler" {
  source          = "./webhook_handler"
  tls_secret_name = var.tls_secret_name
  webhook_secret  = var.webhook_handler_secret
  fb_verify_token = var.webhook_handler_fb_verify_token
  fb_page_token   = var.webhook_handler_fb_page_token
  fb_app_secret   = var.webhook_handler_fb_app_secret
  git_user        = var.webhook_handler_git_user
  git_token       = var.webhook_handler_git_token
  ssh_key         = var.webhook_handler_ssh_key

  depends_on = [null_resource.core_services]
}

module "wireguard" {
  source          = "./wireguard"
  tls_secret_name = var.tls_secret_name
  wg_0_conf       = var.wireguard_wg_0_conf
  wg_0_key        = var.wireguard_wg_0_key
  firewall_sh     = var.wireguard_firewall_sh
}
