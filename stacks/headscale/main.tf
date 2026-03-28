variable "tls_secret_name" { type = string }
variable "nfs_server" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "platform"
}

locals {
  homepage_credentials = jsondecode(data.vault_kv_secret_v2.secrets.data["homepage_credentials"])
}

module "headscale" {
  source                 = "./modules/headscale"
  tls_secret_name        = var.tls_secret_name
  nfs_server             = var.nfs_server
  headscale_config       = data.vault_kv_secret_v2.secrets.data["headscale_config"]
  headscale_acl          = data.vault_kv_secret_v2.secrets.data["headscale_acl"]
  homepage_token         = try(local.homepage_credentials["headscale"]["api_key"], "")
  tier                   = local.tiers.core
  ui_cookie_secret       = data.vault_kv_secret_v2.secrets.data["headscale_ui_cookie_secret"]
  ui_api_key             = data.vault_kv_secret_v2.secrets.data["headscale_ui_api_key"]
}
