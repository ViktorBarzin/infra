# =============================================================================
# CrowdSec Stack — Security/WAF
# =============================================================================

variable "tls_secret_name" { type = string }
variable "mysql_host" { type = string }
variable "postgresql_host" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "platform"
}

locals {
  homepage_credentials = jsondecode(data.vault_kv_secret_v2.secrets.data["homepage_credentials"])
}

module "crowdsec" {
  source                         = "./modules/crowdsec"
  tier                           = local.tiers.cluster
  tls_secret_name                = var.tls_secret_name
  mysql_host                     = var.mysql_host
  postgresql_host                = var.postgresql_host
  homepage_username              = local.homepage_credentials["crowdsec"]["username"]
  homepage_password              = local.homepage_credentials["crowdsec"]["password"]
  enroll_key                     = data.vault_kv_secret_v2.secrets.data["crowdsec_enroll_key"]
  db_password                    = data.vault_kv_secret_v2.secrets.data["crowdsec_db_password"]
  crowdsec_dash_api_key          = data.vault_kv_secret_v2.secrets.data["crowdsec_dash_api_key"]
  crowdsec_dash_machine_id       = data.vault_kv_secret_v2.secrets.data["crowdsec_dash_machine_id"]
  crowdsec_dash_machine_password = data.vault_kv_secret_v2.secrets.data["crowdsec_dash_machine_password"]
  slack_webhook_url              = data.vault_kv_secret_v2.secrets.data["alertmanager_slack_api_url"]
  # Enforcement bouncers. traefik is the in-process L7 plugin and the only one
  # that covers Cloudflare-proxied hosts (i.e. every HTTP host in the zone);
  # firewall is the direct-host nftables bouncer. The kvsync key went with the
  # Cloudflare edge list on 2026-08-18; secret/platform still holds the now-unused
  # kvsync_bouncer_key field, deliberately left rather than deleted.
  traefik_bouncer_key  = data.vault_kv_secret_v2.secrets.data["traefik_bouncer_key"]
  firewall_bouncer_key = data.vault_kv_secret_v2.secrets.data["firewall_bouncer_key"]
}
