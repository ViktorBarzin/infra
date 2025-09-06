variable "prod" {}
variable "tls_secret_name" {}
variable "client_certificate_secret_name" {}
variable "hackmd_db_password" {}
variable "mailserver_accounts" {}
variable "mailserver_aliases" {}
variable "mailserver_opendkim_key" {}
variable "mailserver_sasl_passwd" {}
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
variable "dbaas_postgresql_root_password" {}
variable "dbaas_pgadmin_password" {}
variable "drone_github_client_id" {}
variable "drone_github_client_secret" {}
variable "drone_rpc_secret" {}
variable "oauth2_proxy_client_id" {}
variable "oauth2_proxy_client_secret" {}
variable "oauth2_proxy_authenticated_emails" {}
variable "url_shortener_geolite_license_key" {}
variable "url_shortener_api_key" {}
variable "url_shortener_mysql_password" {}
variable "webhook_handler_fb_verify_token" {}
variable "webhook_handler_fb_page_token" {}
variable "webhook_handler_fb_app_secret" {}
variable "webhook_handler_git_user" {}
variable "webhook_handler_git_token" {}
variable "webhook_handler_ssh_key" {}
variable "technitium_username" {}
variable "technitium_password" {}
variable "idrac_username" {}
variable "idrac_password" {}
variable "alertmanager_slack_api_url" {}
variable "home_assistant_configuration" {}
variable "shadowsocks_password" {}
variable "finance_app_db_connection_string" {}
variable "finance_app_currency_converter_api_key" {}
variable "finance_app_graphql_api_secret" {}
variable "finance_app_gocardless_secret_key" {}
variable "finance_app_gocardless_secret_id" {}
variable "headscale_config" {}
variable "headscale_acl" {}
variable "immich_postgresql_password" {}
variable "ingress_honeypotapikey" {}
variable "ingress_crowdsec_api_key" {}
variable "ingress_crowdsec_captcha_secret_key" {}
variable "ingress_crowdsec_captcha_site_key" {}
variable "crowdsec_enroll_key" { type = string }
variable "crowdsec_db_password" { type = string }
variable "vaultwarden_smtp_password" {}
variable "resume_database_url" {}
variable "resume_redis_url" {}
variable "frigate_valchedrym_camera_credentials" { default = "" }
variable "paperless_db_password" {}
variable "diun_nfty_token" {}
variable "diun_slack_url" {}
variable "nextcloud_db_password" {}
variable "homepage_credentials" {}
variable "authentik_secret_key" {}
variable "authentik_postgres_password" {}
variable "linkwarden_postgresql_password" {}
variable "linkwarden_authentik_client_id" {}
variable "linkwarden_authentik_client_secret" {}
variable "cloudflare_tunnel_token" {}
variable "cloudflare_api_key" {}
variable "cloudflare_email" {}
variable "cloudflare_account_id" {}
variable "cloudflare_zone_id" {}
variable "cloudflare_tunnel_id" {}
variable "public_ip" {}
variable "cloudflare_proxied_names" {}
variable "cloudflare_non_proxied_names" {}
variable "owntracks_credentials" {}
variable "dawarich_database_password" {}
variable "geoapify_api_key" {}
variable "tandoor_database_password" {}
variable "tandoor_email_password" {}
variable "n8n_postgresql_password" {}
variable "realestate_crawler_db_password" {}
variable "realestate_crawler_notification_settings" {
  type = map(string)
  default = {
  }
}
variable "kured_notify_url" {}
variable "onlyoffice_db_password" { type = string }
variable "onlyoffice_jwt_token" { type = string }
variable "xray_reality_clients" { type = list(map(string)) }
variable "xray_reality_private_key" { type = string }
variable "xray_reality_short_ids" { type = list(string) }



variable "defcon_level" {
  type    = number
  default = 5
  validation {
    condition     = var.defcon_level >= 1 && var.defcon_level <= 5
    error_message = "DEFCON level must be between 1 and 5"
  }
}
locals {
  defcon_modules = {
    1 : [],
    2 : [],
    3 : [],
    4 : [],
    5 : ["blog"],
  }
  active_modules = distinct(flatten([
    for level in range(1, var.defcon_level + 1) : # From current level to 5
    lookup(local.defcon_modules, level, [])
  ]))
}

resource "null_resource" "core_services" {
  # List all the core modules that must be provisioned first
  depends_on = [module.metallb]
}

module "blog" {
  count           = contains(local.active_modules, "blog") ? 1 : 0
  source          = "./blog"
  tls_secret_name = var.tls_secret_name
  # dockerhub_password = var.dockerhub_password

  depends_on = [null_resource.core_services]
}

# module "bind" {
#   source              = "./bind"
#   db_viktorbarzin_me  = var.bind_db_viktorbarzin_me
#   db_viktorbarzin_lan = var.bind_db_viktorbarzin_lan
#   named_conf_options  = var.bind_named_conf_options
# }

module "dbaas" {
  source                   = "./dbaas"
  prod                     = var.prod
  tls_secret_name          = var.tls_secret_name
  dbaas_root_password      = var.dbaas_root_password
  postgresql_root_password = var.dbaas_postgresql_root_password
  pgadmin_password         = var.dbaas_pgadmin_password
}

module "descheduler" {
  source = "./descheduler"
}

# module "dnscrypt" {
#   source = "./dnscrypt"
# }

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

# module "kafka" {
#   source                         = "./kafka"
#   client_certificate_secret_name = var.client_certificate_secret_name
#   tls_secret_name                = var.tls_secret_name
# }

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
  sasl_passwd             = var.mailserver_sasl_passwd

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
  alertmanager_slack_api_url    = var.alertmanager_slack_api_url

  depends_on = [null_resource.core_services]
}

# module "oauth" {
#   source                     = "./oauth-proxy"
#   tls_secret_name            = var.tls_secret_name
#   oauth2_proxy_client_id     = var.oauth2_proxy_client_id
#   oauth2_proxy_client_secret = var.oauth2_proxy_client_secret
#   authenticated_emails       = var.oauth2_proxy_authenticated_emails

#   depends_on = [null_resource.core_services]
# }

# module "openid_help_page" {
#   source          = "./openid_help_page"
#   tls_secret_name = var.tls_secret_name

#   depends_on = [null_resource.core_services]
# }

# module "pihole" {
#   source       = "./pihole"
#   web_password = var.pihole_web_password

#   tls_secret_name = var.tls_secret_name

#   depends_on = [module.bind] # DNS goes like pihole -> bind -> dnscrypt
# }

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

module "shadowsocks" {
  source   = "./shadowsocks"
  password = var.shadowsocks_password
}

module "city-guesser" {
  source          = "./city-guesser"
  tls_secret_name = var.tls_secret_name
  depends_on      = [null_resource.core_services]
}

module "echo" {
  source          = "./echo"
  tls_secret_name = var.tls_secret_name
  depends_on      = [null_resource.core_services]
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

# module "home_assistant" {
#   source                         = "./home_assistant"
#   tls_secret_name                = var.tls_secret_name
#   client_certificate_secret_name = var.client_certificate_secret_name
#   configuration_yaml             = var.home_assistant_configuration
# }

module "finance_app" {
  source                     = "./finance_app"
  tls_secret_name            = var.tls_secret_name
  graphql_api_secret         = var.finance_app_graphql_api_secret
  db_connection_string       = var.finance_app_db_connection_string
  currency_converter_api_key = var.finance_app_currency_converter_api_key
  gocardless_secret_key      = var.finance_app_gocardless_secret_key
  gocardless_secret_id       = var.finance_app_gocardless_secret_id
}

module "excalidraw" {
  source          = "./excalidraw"
  tls_secret_name = var.tls_secret_name
}

module "infra-maintenance" {
  source              = "./infra-maintenance"
  git_user            = var.webhook_handler_git_user
  git_token           = var.webhook_handler_git_token
  technitium_username = var.technitium_username
  technitium_password = var.technitium_password
}

module "travel_blog" {
  source          = "./travel_blog"
  tls_secret_name = var.tls_secret_name
}

module "technitium" {
  source          = "./technitium"
  tls_secret_name = var.tls_secret_name
  homepage_token  = var.homepage_credentials["technitium"]["token"]
}

module "headscale" {
  source           = "./headscale"
  tls_secret_name  = var.tls_secret_name
  headscale_config = var.headscale_config
  headscale_acl    = var.headscale_acl
}

module "dashy" {
  source          = "./dashy"
  tls_secret_name = var.tls_secret_name
}

# module "localai" {
#   source          = "./localai"
#   tls_secret_name = var.tls_secret_name
# }

module "vaultwarden" {
  source          = "./vaultwarden"
  tls_secret_name = var.tls_secret_name
  smtp_password   = var.vaultwarden_smtp_password
}

module "reverse-proxy" {
  source                 = "./reverse_proxy"
  tls_secret_name        = var.tls_secret_name
  truenas_homepage_token = var.homepage_credentials["reverse_proxy"]["truenas_token"]
  pfsense_homepage_token = var.homepage_credentials["reverse_proxy"]["pfsense_token"]
}

# Selfhosted Firefox send
module "send" {
  source          = "./send"
  tls_secret_name = var.tls_secret_name
}

module "redis" {
  source          = "./redis"
  tls_secret_name = var.tls_secret_name
}

module "ytdlp" {
  source          = "./youtube_dl"
  tls_secret_name = var.tls_secret_name
}

module "immich" {
  source              = "./immich"
  tls_secret_name     = var.tls_secret_name
  postgresql_password = var.immich_postgresql_password
  homepage_token      = var.homepage_credentials["immich"]["token"]
}

module "nginx-ingress" {
  source                      = "./nginx-ingress"
  honeypotapikey              = var.ingress_honeypotapikey
  crowdsec_api_key            = var.ingress_crowdsec_api_key
  crowdsec_captcha_secret_key = var.ingress_crowdsec_captcha_secret_key
  crowdsec_captcha_site_key   = var.ingress_crowdsec_captcha_site_key
}

module "crowdsec" {
  source            = "./crowdsec"
  tls_secret_name   = var.tls_secret_name
  homepage_username = var.homepage_credentials["crowdsec"]["username"]
  homepage_password = var.homepage_credentials["crowdsec"]["password"]
  enroll_key        = var.crowdsec_enroll_key
  db_password       = var.crowdsec_db_password
}

# Seems like it needs S3 even if pg is local...
# module "resume" {
#   source          = "./resume"
#   tls_secret_name = var.tls_secret_name
#   redis_url       = var.resume_redis_url
#   database_url    = var.resume_database_url
# }

module "uptime-kuma" {
  source          = "./uptime-kuma"
  tls_secret_name = var.tls_secret_name
}

module "calibre" {
  source            = "./calibre"
  tls_secret_name   = var.tls_secret_name
  homepage_username = var.homepage_credentials["calibre-web"]["username"]
  homepage_password = var.homepage_credentials["calibre-web"]["password"]
}

# Audiobooks are served using audiobookshelf; still looking for a usecawe for JF
# module "jellyfin" {
#   source          = "./jellyfin"
#   tls_secret_name = var.tls_secret_name
# }

module "audiobookshelf" {
  source          = "./audiobookshelf"
  tls_secret_name = var.tls_secret_name
}

module "frigate" {
  source          = "./frigate"
  tls_secret_name = var.tls_secret_name
}

# TODO: Currently very unstable and half of the functionality does not work:
# notifications, import from todoist, email
# module "vikunja" {
#   source          = "./vikunja"
#   tls_secret_name = var.tls_secret_name
# }

module "cloudflared" {
  source          = "./cloudflared"
  tls_secret_name = var.tls_secret_name

  cloudflare_api_key           = var.cloudflare_api_key
  cloudflare_email             = var.cloudflare_email
  cloudflare_account_id        = var.cloudflare_account_id
  cloudflare_zone_id           = var.cloudflare_zone_id
  cloudflare_tunnel_id         = var.cloudflare_tunnel_id
  public_ip                    = var.public_ip
  cloudflare_proxied_names     = var.cloudflare_proxied_names
  cloudflare_non_proxied_names = var.cloudflare_non_proxied_names
  cloudflare_tunnel_token      = var.cloudflare_tunnel_token
}

# module "istio" {
#   source          = "./istio"
#   tls_secret_name = var.tls_secret_name
# }

# module "authelia" {
#   source          = "./authelia"
#   tls_secret_name = var.tls_secret_name
# }

# module "discount-bandit" {
#   source          = "./discount-bandit"
#   tls_secret_name = var.tls_secret_name
# }

module "metrics-server" {
  source          = "./metrics-server"
  tls_secret_name = var.tls_secret_name
}

module "paperless-ngx" {
  source          = "./paperless-ngx"
  tls_secret_name = var.tls_secret_name
  db_password     = var.paperless_db_password
  # homepage_token  = var.homepage_credentials["paperless-ngx"]["token"]
  homepage_username = var.homepage_credentials["paperless-ngx"]["username"]
  homepage_password = var.homepage_credentials["paperless-ngx"]["password"]
}

module "jsoncrack" {
  source          = "./jsoncrack"
  tls_secret_name = var.tls_secret_name
}

# module "servarr" {
#   source          = "./servarr"
#   tls_secret_name = var.tls_secret_name
# }

# module "dnscat2" {
#   source = "./dnscat2"
#   # tls_secret_name = var.tls_secret_name
# }

# module "ollama" {  # Disabled as it requires too much resources...
#   source          = "./ollama"
#   tls_secret_name = var.tls_secret_name
# }

module "ntfy" {
  source          = "./ntfy"
  tls_secret_name = var.tls_secret_name
}

module "cyberchef" {
  source          = "./cyberchef"
  tls_secret_name = var.tls_secret_name
}

module "diun" {
  source          = "./diun"
  tls_secret_name = var.tls_secret_name
  diun_nfty_token = var.diun_nfty_token
  diun_slack_url  = var.diun_slack_url
}

module "meshcentral" {
  source          = "./meshcentral"
  tls_secret_name = var.tls_secret_name
}
# module "netbox" {
#   source          = "./netbox"
#   tls_secret_name = var.tls_secret_name
# }

module "nextcloud" {
  source          = "./nextcloud"
  tls_secret_name = var.tls_secret_name
  db_password     = var.nextcloud_db_password
}

module "homepage" {
  source          = "./homepage"
  tls_secret_name = var.tls_secret_name
}

module "matrix" {
  source          = "./matrix"
  tls_secret_name = var.tls_secret_name
}

module "authentik" {
  source            = "./authentik"
  tls_secret_name   = var.tls_secret_name
  secret_key        = var.authentik_secret_key
  postgres_password = var.authentik_postgres_password
}

module "linkwarden" {
  source                  = "./linkwarden"
  tls_secret_name         = var.tls_secret_name
  postgresql_password     = var.linkwarden_postgresql_password
  authentik_client_id     = var.linkwarden_authentik_client_id
  authentik_client_secret = var.linkwarden_authentik_client_secret
}

module "actualbudget" {
  source          = "./actualbudget"
  tls_secret_name = var.tls_secret_name
}

module "owntracks" {
  source                = "./owntracks"
  tls_secret_name       = var.tls_secret_name
  owntracks_credentials = var.owntracks_credentials
}

module "dawarich" {
  source            = "./dawarich"
  tls_secret_name   = var.tls_secret_name
  database_password = var.dawarich_database_password
  geoapify_api_key  = var.geoapify_api_key
}

module "changedetection" {
  source          = "./changedetection"
  tls_secret_name = var.tls_secret_name
}
module "tandoor" {
  source                    = "./tandoor"
  tls_secret_name           = var.tls_secret_name
  tandoor_database_password = var.tandoor_database_password
  tandoor_email_password    = var.tandoor_email_password
}

module "n8n" {
  source              = "./n8n"
  tls_secret_name     = var.tls_secret_name
  postgresql_password = var.n8n_postgresql_password
}

module "real-estate-crawler" {
  source                = "./real-estate-crawler"
  tls_secret_name       = var.tls_secret_name
  db_password           = var.realestate_crawler_db_password
  notification_settings = var.realestate_crawler_notification_settings
}

module "tor-proxy" {
  source          = "./tor-proxy"
  tls_secret_name = var.tls_secret_name
}

# module "kured" {
#   source          = "./kured"
#   tls_secret_name = var.tls_secret_name
#   notify_url      = var.kured_notify_url
# }

module "onlyoffice" {
  source          = "./onlyoffice"
  tls_secret_name = var.tls_secret_name
  db_password     = var.onlyoffice_db_password
  jwt_token       = var.onlyoffice_jwt_token
}


module "forgejo" {
  source          = "./forgejo"
  tls_secret_name = var.tls_secret_name
}

module "xray" {
  source          = "./xray"
  tls_secret_name = var.tls_secret_name

  xray_reality_clients     = var.xray_reality_clients
  xray_reality_private_key = var.xray_reality_private_key
  xray_reality_short_ids   = var.xray_reality_short_ids
}

module "freshrss" {
  source          = "./freshrss"
  tls_secret_name = var.tls_secret_name
}

module "navidrome" {
  source          = "./navidrome"
  tls_secret_name = var.tls_secret_name
}
