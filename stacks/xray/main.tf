variable "tls_secret_name" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "platform"
}

locals {
  xray_reality_clients   = jsondecode(data.vault_kv_secret_v2.secrets.data["xray_reality_clients"])
  xray_reality_short_ids = jsondecode(data.vault_kv_secret_v2.secrets.data["xray_reality_short_ids"])
}

module "xray" {
  source          = "./modules/xray"
  tls_secret_name = var.tls_secret_name
  tier            = local.tiers.core

  xray_reality_clients     = local.xray_reality_clients
  xray_reality_private_key = data.vault_kv_secret_v2.secrets.data["xray_reality_private_key"]
  xray_reality_short_ids   = local.xray_reality_short_ids
}
