# =============================================================================
# CrowdSec Stack — Security/WAF
# =============================================================================

variable "tls_secret_name" { type = string }
variable "mysql_host" { type = string }

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
  homepage_username              = local.homepage_credentials["crowdsec"]["username"]
  homepage_password              = local.homepage_credentials["crowdsec"]["password"]
  enroll_key                     = data.vault_kv_secret_v2.secrets.data["crowdsec_enroll_key"]
  db_password                    = data.vault_kv_secret_v2.secrets.data["crowdsec_db_password"]
  crowdsec_dash_api_key          = data.vault_kv_secret_v2.secrets.data["crowdsec_dash_api_key"]
  crowdsec_dash_machine_id       = data.vault_kv_secret_v2.secrets.data["crowdsec_dash_machine_id"]
  crowdsec_dash_machine_password = data.vault_kv_secret_v2.secrets.data["crowdsec_dash_machine_password"]
  slack_webhook_url              = data.vault_kv_secret_v2.secrets.data["alertmanager_slack_api_url"]
}
