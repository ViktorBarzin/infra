variable "tls_secret_name" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "platform"
}

locals {
  homepage_credentials = jsondecode(data.vault_kv_secret_v2.secrets.data["homepage_credentials"])
}

module "reverse-proxy" {
  source                 = "./modules/reverse_proxy"
  tls_secret_name        = var.tls_secret_name
  pfsense_homepage_token = local.homepage_credentials["reverse_proxy"]["pfsense_token"]
  haos_homepage_token    = try(local.homepage_credentials["home_assistant"]["token"], "")
}
