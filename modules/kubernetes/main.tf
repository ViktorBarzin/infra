variable "prod" {}
variable "tls_secret_name" {}
variable "client_certificate_secret_name" {}
variable "hackmd_db_password" {}
variable "mailserver_accounts" {}
variable "mailserver_aliases" {}
variable "mailserver_opendkim_key" {}
variable "mailserver_roundcubemail_db_password" { type = string }
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
variable "immich_frame_api_key" {}
variable "ingress_honeypotapikey" {}
variable "ingress_crowdsec_api_key" {}
variable "ingress_crowdsec_captcha_secret_key" {}
variable "ingress_crowdsec_captcha_site_key" {}
variable "crowdsec_enroll_key" { type = string }
variable "crowdsec_db_password" { type = string }
variable "crowdsec_dash_api_key" { type = string }
variable "crowdsec_dash_machine_id" { type = string }
variable "crowdsec_dash_machine_password" { type = string }
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
variable "tiny_tuya_api_key" { type = string }
variable "tiny_tuya_api_secret" { type = string }
variable "tiny_tuya_service_secret" { type = string }
variable "tiny_tuya_slack_url" { type = string }
variable "haos_api_token" { type = string }
variable "pve_password" { type = string }
variable "grafana_db_password" { type = string }
variable "clickhouse_password" { type = string }
variable "clickhouse_postgres_password" { type = string }
variable "wealthfolio_password_hash" { type = string }


variable "defcon_level" {
  type    = number
  default = 5
  validation {
    condition     = var.defcon_level >= 1 && var.defcon_level <= 5
    error_message = "DEFCON level must be between 1 and 5. 1 is highest level or alertness"
  }
}
locals {
  defcon_modules = {
    1 : ["wireguard", "technitium", "headscale", "nginx-ingress", "xray", "authentik", "cloudflare", "authelia", "monitoring"], # Critical connectivity services
    2 : ["vaultwarden", "redis", "immich", "nvidia", "metrics-server", "uptime-kuma", "crowdsec"],                              # Storage and other db services
    3 : ["k8s-dashboard", "reverse-proxy"],                                                                                     # Cluster admin services
    4 : [
      "mailserver", "shadowsocks", "webhook_handler", "tuya-bridge", "dawarich", "owntracks", "nextcloud",
      "calibre", "onlyoffice", "f1-stream", "rybbit", "isponsorblocktv", "actualbudget"
    ], # Activel used services
    # Optional services
    5 : [
      "blog", "descheduler", "drone", "hackmd", "kms", "privatebin", "vault", "reloader", "city-guesser", "echo",
      "url", "excalidraw", "travel_blog", "dashy", "send", "ytdlp", "wealthfolio", "rybbit", "stirling-pdf",
      "networking-toolbox", "navidrome", "freshrss", "forgejo", "tor-proxy", "real-estate-crawler", "n8n",
      "changedetection", "linkwarden", "matrix", "homepage", "meshcentral", "diun", "cyberchef", "ntfy", "ollama",
      "servarr", "jsoncrack", "paperless-ngx", "frigate", "audiobookshelf", "tandoor"
    ],
  }
  active_modules = distinct(flatten([
    for level in range(1, var.defcon_level + 1) : # From current level to 5
    lookup(local.defcon_modules, level, [])
  ]))
}

resource "null_resource" "core_services" {
  # List all the core modules that must be provisioned first
  depends_on = [
    module.metallb, module.dbaas, module.technitium, module.vaultwarden, module.reverse-proxy,
    module.redis, module.nginx-ingress, module.crowdsec, module.cloudflared, module.metrics-server, module.authentik,
    module.nvidia,
  ]
}

module "blog" {
  for_each        = contains(local.active_modules, "blog") ? { blog = true } : {}
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
  source     = "./descheduler"
  for_each   = contains(local.active_modules, "descheduler") ? { descheduler = true } : {}
  depends_on = [null_resource.core_services]
}

# module "dnscrypt" {
#   source = "./dnscrypt"
# }

# CI/CD
module "drone" {
  source          = "./drone"
  for_each        = contains(local.active_modules, "drone") ? { drone = true } : {}
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
  for_each        = contains(local.active_modules, "f1-stream") ? { f1-stream = true } : {}
  tls_secret_name = var.tls_secret_name

  depends_on = [null_resource.core_services]
}

module "hackmd" {
  source             = "./hackmd"
  for_each           = contains(local.active_modules, "hackmd") ? { hackmd = true } : {}
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
  for_each        = contains(local.active_modules, "kms") ? { kms = true } : {}
  tls_secret_name = var.tls_secret_name

  depends_on = [null_resource.core_services]
}

module "k8s-dashboard" {
  source                         = "./k8s-dashboard"
  for_each                       = contains(local.active_modules, "k8s-dashboard") ? { k8s-dashboard = true } : {}
  tls_secret_name                = var.tls_secret_name
  client_certificate_secret_name = var.client_certificate_secret_name

  depends_on = [null_resource.core_services]
}

module "mailserver" {
  source                  = "./mailserver"
  for_each                = contains(local.active_modules, "mailserver") ? { mailserver = true } : {}
  tls_secret_name         = var.tls_secret_name
  mailserver_accounts     = var.mailserver_accounts
  postfix_account_aliases = var.mailserver_aliases
  opendkim_key            = var.mailserver_opendkim_key
  sasl_passwd             = var.mailserver_sasl_passwd
  roundcube_db_password   = var.mailserver_roundcubemail_db_password

  depends_on = [null_resource.core_services]
}

module "metallb" {
  source = "./metallb"
}

module "monitoring" {
  source                        = "./monitoring"
  tls_secret_name               = var.tls_secret_name
  for_each                      = contains(local.active_modules, "monitoring") ? { monitoring = true } : {}
  alertmanager_account_password = var.alertmanager_account_password
  idrac_username                = var.idrac_username
  idrac_password                = var.idrac_password
  alertmanager_slack_api_url    = var.alertmanager_slack_api_url
  tiny_tuya_service_secret      = var.tiny_tuya_service_secret
  haos_api_token                = var.haos_api_token
  pve_password                  = var.pve_password
  grafana_db_password           = var.grafana_db_password
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
  for_each        = contains(local.active_modules, "privatebin") ? { privatebin = true } : {}
  tls_secret_name = var.tls_secret_name

  depends_on = [null_resource.core_services]
}

module "vault" {
  source          = "./vault"
  for_each        = contains(local.active_modules, "vault") ? { vault = true } : {}
  tls_secret_name = var.tls_secret_name

  depends_on = [null_resource.core_services]
}

module "reloader" {
  source   = "./reloader"
  for_each = contains(local.active_modules, "reloader") ? { reloader = true } : {}

  depends_on = [null_resource.core_services]
}

module "shadowsocks" {
  source   = "./shadowsocks"
  for_each = contains(local.active_modules, "shadowsocks") ? { shadowsocks = true } : {}
  password = var.shadowsocks_password

  depends_on = [null_resource.core_services]
}

module "city-guesser" {
  source          = "./city-guesser"
  for_each        = contains(local.active_modules, "city-guesser") ? { city-guesser = true } : {}
  tls_secret_name = var.tls_secret_name
  depends_on      = [null_resource.core_services]
}

module "echo" {
  source          = "./echo"
  for_each        = contains(local.active_modules, "echo") ? { echo = true } : {}
  tls_secret_name = var.tls_secret_name
  depends_on      = [null_resource.core_services]
}

module "url" {
  source              = "./url-shortener"
  for_each            = contains(local.active_modules, "url") ? { url = true } : {}
  tls_secret_name     = var.tls_secret_name
  geolite_license_key = var.url_shortener_geolite_license_key
  api_key             = var.url_shortener_api_key
  mysql_password      = var.url_shortener_mysql_password

  depends_on = [null_resource.core_services]
}

module "webhook_handler" {
  source          = "./webhook_handler"
  for_each        = contains(local.active_modules, "webhook_handler") ? { webhook_handler = true } : {}
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
  for_each        = contains(local.active_modules, "wireguard") ? { wireguard = true } : {}
  tls_secret_name = var.tls_secret_name
  wg_0_conf       = var.wireguard_wg_0_conf
  wg_0_key        = var.wireguard_wg_0_key
  firewall_sh     = var.wireguard_firewall_sh

  depends_on = [null_resource.core_services]
}

# module "home_assistant" {
#   source                         = "./home_assistant"
#   tls_secret_name                = var.tls_secret_name
#   client_certificate_secret_name = var.client_certificate_secret_name
#   configuration_yaml             = var.home_assistant_configuration
# }

# module "finance_app" {
#   source                     = "./finance_app"
#   tls_secret_name            = var.tls_secret_name
#   graphql_api_secret         = var.finance_app_graphql_api_secret
#   db_connection_string       = var.finance_app_db_connection_string
#   currency_converter_api_key = var.finance_app_currency_converter_api_key
#   gocardless_secret_key      = var.finance_app_gocardless_secret_key
#   gocardless_secret_id       = var.finance_app_gocardless_secret_id
# }

module "excalidraw" {
  source          = "./excalidraw"
  for_each        = contains(local.active_modules, "excalidraw") ? { excalidraw = true } : {}
  tls_secret_name = var.tls_secret_name

  depends_on = [null_resource.core_services]
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
  for_each        = contains(local.active_modules, "travel_blog") ? { travel_blog = true } : {}
  tls_secret_name = var.tls_secret_name

  depends_on = [null_resource.core_services]
}

module "technitium" {
  source          = "./technitium"
  for_each        = contains(local.active_modules, "technitium") ? { technitium = true } : {}
  tls_secret_name = var.tls_secret_name
  homepage_token  = var.homepage_credentials["technitium"]["token"]
}

module "headscale" {
  source           = "./headscale"
  for_each         = contains(local.active_modules, "headscale") ? { headscale = true } : {}
  tls_secret_name  = var.tls_secret_name
  headscale_config = var.headscale_config
  headscale_acl    = var.headscale_acl

  depends_on = [null_resource.core_services]
}

module "dashy" {
  source          = "./dashy"
  for_each        = contains(local.active_modules, "dashy") ? { dashy = true } : {}
  tls_secret_name = var.tls_secret_name

  depends_on = [null_resource.core_services]
}

# module "localai" {
#   source          = "./localai"
#   tls_secret_name = var.tls_secret_name
# }

module "vaultwarden" {
  source          = "./vaultwarden"
  for_each        = contains(local.active_modules, "vaultwarden") ? { vaultwarden = true } : {}
  tls_secret_name = var.tls_secret_name
  smtp_password   = var.vaultwarden_smtp_password
}

module "reverse-proxy" {
  source                 = "./reverse_proxy"
  for_each               = contains(local.active_modules, "reverse-proxy") ? { reverse-proxy = true } : {}
  tls_secret_name        = var.tls_secret_name
  truenas_homepage_token = var.homepage_credentials["reverse_proxy"]["truenas_token"]
  pfsense_homepage_token = var.homepage_credentials["reverse_proxy"]["pfsense_token"]
}

# Selfhosted Firefox send
module "send" {
  source          = "./send"
  for_each        = contains(local.active_modules, "send") ? { send = true } : {}
  tls_secret_name = var.tls_secret_name

  depends_on = [null_resource.core_services]
}

module "redis" {
  source          = "./redis"
  for_each        = contains(local.active_modules, "redis") ? { redis = true } : {}
  tls_secret_name = var.tls_secret_name
}

module "ytdlp" {
  source          = "./youtube_dl"
  for_each        = contains(local.active_modules, "ytdlp") ? { ytdlp = true } : {}
  tls_secret_name = var.tls_secret_name

  depends_on = [null_resource.core_services]
}

module "immich" {
  source              = "./immich"
  for_each            = contains(local.active_modules, "immich") ? { immich = true } : {}
  tls_secret_name     = var.tls_secret_name
  postgresql_password = var.immich_postgresql_password
  frame_api_key       = var.immich_frame_api_key
  homepage_token      = var.homepage_credentials["immich"]["token"]

  depends_on = [null_resource.core_services]
}

module "nginx-ingress" {
  source                      = "./nginx-ingress"
  for_each                    = contains(local.active_modules, "nginx-ingress") ? { nginx-ingress = true } : {}
  honeypotapikey              = var.ingress_honeypotapikey
  crowdsec_api_key            = var.ingress_crowdsec_api_key
  crowdsec_captcha_secret_key = var.ingress_crowdsec_captcha_secret_key
  crowdsec_captcha_site_key   = var.ingress_crowdsec_captcha_site_key
}

module "crowdsec" {
  source                         = "./crowdsec"
  for_each                       = contains(local.active_modules, "crowdsec") ? { crowdsec = true } : {}
  tls_secret_name                = var.tls_secret_name
  homepage_username              = var.homepage_credentials["crowdsec"]["username"]
  homepage_password              = var.homepage_credentials["crowdsec"]["password"]
  enroll_key                     = var.crowdsec_enroll_key
  db_password                    = var.crowdsec_db_password
  crowdsec_dash_api_key          = var.crowdsec_dash_api_key
  crowdsec_dash_machine_id       = var.crowdsec_dash_machine_id
  crowdsec_dash_machine_password = var.crowdsec_dash_machine_password
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
  for_each        = contains(local.active_modules, "uptime-kuma") ? { uptime-kuma = true } : {}
  tls_secret_name = var.tls_secret_name

  depends_on = [null_resource.core_services]
}

module "calibre" {
  source            = "./calibre"
  for_each          = contains(local.active_modules, "calibre") ? { calibre = true } : {}
  tls_secret_name   = var.tls_secret_name
  homepage_username = var.homepage_credentials["calibre-web"]["username"]
  homepage_password = var.homepage_credentials["calibre-web"]["password"]

  depends_on = [null_resource.core_services]
}

# Audiobooks are served using audiobookshelf; still looking for a usecawe for JF
# module "jellyfin" {
#   source          = "./jellyfin"
#   tls_secret_name = var.tls_secret_name
# }

module "audiobookshelf" {
  source          = "./audiobookshelf"
  for_each        = contains(local.active_modules, "audiobookshelf") ? { audiobookshelf = true } : {}
  tls_secret_name = var.tls_secret_name

  depends_on = [null_resource.core_services]
}

module "frigate" {
  source          = "./frigate"
  for_each        = contains(local.active_modules, "frigate") ? { frigate = true } : {}
  tls_secret_name = var.tls_secret_name

  depends_on = [null_resource.core_services]
}

# TODO: Currently very unstable and half of the functionality does not work:
# notifications, import from todoist, email
# module "vikunja" {
#   source          = "./vikunja"
#   tls_secret_name = var.tls_secret_name
# }

module "cloudflared" {
  source = "./cloudflared"
  # for_each        = contains(local.active_modules, "cloudflared") ? { cloudflared = true } : {}
  tls_secret_name = var.tls_secret_name

  cloudflare_api_key           = var.cloudflare_api_key
  cloudflare_email             = var.cloudflare_email
  cloudflare_account_id        = var.cloudflare_account_id
  cloudflare_zone_id           = var.cloudflare_zone_id
  cloudflare_tunnel_id         = var.cloudflare_tunnel_id
  public_ip                    = var.public_ip
  cloudflare_proxied_names     = var.cloudflare_proxied_names
  cloudflare_non_proxied_names = var.cloudflare_non_proxied_names
  # cloudflare_proxied_names     = []
  # cloudflare_non_proxied_names = []
  cloudflare_tunnel_token = var.cloudflare_tunnel_token
}

# module "istio" {
#   source          = "./istio"
#   tls_secret_name = var.tls_secret_name
# }

# module "authelia" {
#   source          = "./authelia"
#   for_each        = contains(local.active_modules, "authelia") ? { authelia = true } : {}
#   tls_secret_name = var.tls_secret_name
# }

# module "discount-bandit" {
#   source          = "./discount-bandit"
#   tls_secret_name = var.tls_secret_name
# }

module "metrics-server" {
  source          = "./metrics-server"
  for_each        = contains(local.active_modules, "metrics-server") ? { metrics-server = true } : {}
  tls_secret_name = var.tls_secret_name
}

module "paperless-ngx" {
  source          = "./paperless-ngx"
  for_each        = contains(local.active_modules, "paperless-ngx") ? { paperless-ngx = true } : {}
  tls_secret_name = var.tls_secret_name
  db_password     = var.paperless_db_password
  # homepage_token  = var.homepage_credentials["paperless-ngx"]["token"]
  homepage_username = var.homepage_credentials["paperless-ngx"]["username"]
  homepage_password = var.homepage_credentials["paperless-ngx"]["password"]

  depends_on = [null_resource.core_services]
}

module "jsoncrack" {
  source          = "./jsoncrack"
  for_each        = contains(local.active_modules, "jsoncrack") ? { jsoncrack = true } : {}
  tls_secret_name = var.tls_secret_name

  depends_on = [null_resource.core_services]
}

module "servarr" {
  source          = "./servarr"
  for_each        = contains(local.active_modules, "servarr") ? { servarr = true } : {}
  tls_secret_name = var.tls_secret_name

  depends_on = [null_resource.core_services]
}

# module "dnscat2" {
#   source = "./dnscat2"
#   # tls_secret_name = var.tls_secret_name
# }

module "ollama" { # Disabled as it requires too much resources...
  source          = "./ollama"
  for_each        = contains(local.active_modules, "ollama") ? { ollama = true } : {}
  tls_secret_name = var.tls_secret_name

  depends_on = [null_resource.core_services]
}

module "ntfy" {
  source          = "./ntfy"
  for_each        = contains(local.active_modules, "ntfy") ? { ntfy = true } : {}
  tls_secret_name = var.tls_secret_name

  depends_on = [null_resource.core_services]
}

module "cyberchef" {
  source          = "./cyberchef"
  for_each        = contains(local.active_modules, "cyberchef") ? { cyberchef = true } : {}
  tls_secret_name = var.tls_secret_name

  depends_on = [null_resource.core_services]
}

module "diun" {
  source          = "./diun"
  for_each        = contains(local.active_modules, "diun") ? { diun = true } : {}
  tls_secret_name = var.tls_secret_name
  diun_nfty_token = var.diun_nfty_token
  diun_slack_url  = var.diun_slack_url

  depends_on = [null_resource.core_services]
}

module "meshcentral" {
  source          = "./meshcentral"
  for_each        = contains(local.active_modules, "meshcentral") ? { meshcentral = true } : {}
  tls_secret_name = var.tls_secret_name

  depends_on = [null_resource.core_services]
}
# module "netbox" {
#   source          = "./netbox"
#   tls_secret_name = var.tls_secret_name
# }

module "nextcloud" {
  source          = "./nextcloud"
  for_each        = contains(local.active_modules, "nextcloud") ? { nextcloud = true } : {}
  tls_secret_name = var.tls_secret_name
  db_password     = var.nextcloud_db_password

  depends_on = [null_resource.core_services]
}

module "homepage" {
  source          = "./homepage"
  for_each        = contains(local.active_modules, "homepage") ? { homepage = true } : {}
  tls_secret_name = var.tls_secret_name

  depends_on = [null_resource.core_services]
}

module "matrix" {
  source          = "./matrix"
  for_each        = contains(local.active_modules, "matrix") ? { matrix = true } : {}
  tls_secret_name = var.tls_secret_name

  depends_on = [null_resource.core_services]
}

module "authentik" {
  source            = "./authentik"
  for_each          = contains(local.active_modules, "authentik") ? { authentik = true } : {}
  tls_secret_name   = var.tls_secret_name
  secret_key        = var.authentik_secret_key
  postgres_password = var.authentik_postgres_password
}

module "linkwarden" {
  source                  = "./linkwarden"
  for_each                = contains(local.active_modules, "linkwarden") ? { linkwarden = true } : {}
  tls_secret_name         = var.tls_secret_name
  postgresql_password     = var.linkwarden_postgresql_password
  authentik_client_id     = var.linkwarden_authentik_client_id
  authentik_client_secret = var.linkwarden_authentik_client_secret

  depends_on = [null_resource.core_services]
}

module "actualbudget" {
  source          = "./actualbudget"
  for_each        = contains(local.active_modules, "actualbudget") ? { actualbudget = true } : {}
  tls_secret_name = var.tls_secret_name

  depends_on = [null_resource.core_services]
}

module "owntracks" {
  source                = "./owntracks"
  for_each              = contains(local.active_modules, "owntracks") ? { owntracks = true } : {}
  tls_secret_name       = var.tls_secret_name
  owntracks_credentials = var.owntracks_credentials

  depends_on = [null_resource.core_services]
}

module "dawarich" {
  source            = "./dawarich"
  for_each          = contains(local.active_modules, "dawarich") ? { dawarich = true } : {}
  tls_secret_name   = var.tls_secret_name
  database_password = var.dawarich_database_password
  geoapify_api_key  = var.geoapify_api_key

  depends_on = [null_resource.core_services]
}

module "changedetection" {
  source          = "./changedetection"
  for_each        = contains(local.active_modules, "changedetection") ? { changedetection = true } : {}
  tls_secret_name = var.tls_secret_name

  depends_on = [null_resource.core_services]
}
module "tandoor" {
  source                    = "./tandoor"
  for_each                  = contains(local.active_modules, "tandoor") ? { tandoor = true } : {}
  tls_secret_name           = var.tls_secret_name
  tandoor_database_password = var.tandoor_database_password
  tandoor_email_password    = var.tandoor_email_password

  depends_on = [null_resource.core_services]
}

module "n8n" {
  source              = "./n8n"
  for_each            = contains(local.active_modules, "n8n") ? { n8n = true } : {}
  tls_secret_name     = var.tls_secret_name
  postgresql_password = var.n8n_postgresql_password

  depends_on = [null_resource.core_services]
}

module "real-estate-crawler" {
  source                = "./real-estate-crawler"
  for_each              = contains(local.active_modules, "real-estate-crawler") ? { real-estate-crawler = true } : {}
  tls_secret_name       = var.tls_secret_name
  db_password           = var.realestate_crawler_db_password
  notification_settings = var.realestate_crawler_notification_settings

  depends_on = [null_resource.core_services]
}

module "tor-proxy" {
  source          = "./tor-proxy"
  for_each        = contains(local.active_modules, "tor-proxy") ? { tor-proxy = true } : {}
  tls_secret_name = var.tls_secret_name

  depends_on = [null_resource.core_services]
}

# module "kured" {
#   source          = "./kured"
#   tls_secret_name = var.tls_secret_name
#   notify_url      = var.kured_notify_url
# }

module "onlyoffice" {
  source          = "./onlyoffice"
  for_each        = contains(local.active_modules, "onlyoffice") ? { onlyoffice = true } : {}
  tls_secret_name = var.tls_secret_name
  db_password     = var.onlyoffice_db_password
  jwt_token       = var.onlyoffice_jwt_token

  depends_on = [null_resource.core_services]
}


module "forgejo" {
  source          = "./forgejo"
  for_each        = contains(local.active_modules, "forgejo") ? { forgejo = true } : {}
  tls_secret_name = var.tls_secret_name

  depends_on = [null_resource.core_services]
}

module "xray" {
  source          = "./xray"
  for_each        = contains(local.active_modules, "xray") ? { xray = true } : {}
  tls_secret_name = var.tls_secret_name

  xray_reality_clients     = var.xray_reality_clients
  xray_reality_private_key = var.xray_reality_private_key
  xray_reality_short_ids   = var.xray_reality_short_ids

  depends_on = [null_resource.core_services]
}

module "freshrss" {
  source          = "./freshrss"
  for_each        = contains(local.active_modules, "freshrss") ? { freshrss = true } : {}
  tls_secret_name = var.tls_secret_name

  depends_on = [null_resource.core_services]
}

module "navidrome" {
  source          = "./navidrome"
  for_each        = contains(local.active_modules, "navidrome") ? { navidrome = true } : {}
  tls_secret_name = var.tls_secret_name

  depends_on = [null_resource.core_services]
}

module "networking-toolbox" {
  source          = "./networking-toolbox"
  for_each        = contains(local.active_modules, "networking-toolbox") ? { networking-toolbox = true } : {}
  tls_secret_name = var.tls_secret_name

  depends_on = [null_resource.core_services]
}

module "tuya-bridge" {
  source          = "./tuya-bridge"
  for_each        = contains(local.active_modules, "tuya-bridge") ? { tuya-bridge = true } : {}
  tls_secret_name = var.tls_secret_name

  tiny_tuya_api_key        = var.tiny_tuya_api_key
  tiny_tuya_api_secret     = var.tiny_tuya_api_secret
  tiny_tuya_service_secret = var.tiny_tuya_service_secret
  slack_url                = var.tiny_tuya_slack_url

  depends_on = [null_resource.core_services]
}


module "stirling-pdf" {
  source          = "./stirling-pdf"
  for_each        = contains(local.active_modules, "stirling-pdf") ? { stirling-pdf = true } : {}
  tls_secret_name = var.tls_secret_name

  depends_on = [null_resource.core_services]
}

module "isponsorblocktv" {
  source   = "./isponsorblocktv"
  for_each = contains(local.active_modules, "isponsorblocktv") ? { isponsorblocktv = true } : {}

  depends_on = [null_resource.core_services]
}

module "nvidia" {
  source          = "./nvidia"
  for_each        = contains(local.active_modules, "nvidia") ? { nvidia = true } : {}
  tls_secret_name = var.tls_secret_name
}

# module "ebook2audiobook" {
#   source          = "./ebook2audiobook"
#   tls_secret_name = var.tls_secret_name
# }

module "rybbit" {
  source              = "./rybbit"
  for_each            = contains(local.active_modules, "rybbit") ? { rybbit = true } : {}
  tls_secret_name     = var.tls_secret_name
  clickhouse_password = var.clickhouse_password
  postgres_password   = var.clickhouse_postgres_password

  depends_on = [null_resource.core_services]
}

module "wealthfolio" {
  source                    = "./wealthfolio"
  for_each                  = contains(local.active_modules, "wealthfolio") ? { wealthfolio = true } : {}
  tls_secret_name           = var.tls_secret_name
  wealthfolio_password_hash = var.wealthfolio_password_hash

  depends_on = [null_resource.core_services]
}
