variable "tls_secret_name" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "platform"
}

# OPNsense's read-only API key for the Homepage widget, created by
# playbooks/opnsense.yml --tags users.
data "vault_kv_secret_v2" "opnsense" {
  mount = "secret"
  name  = "opnsense"
}

locals {
  homepage_credentials = jsondecode(data.vault_kv_secret_v2.secrets.data["homepage_credentials"])
}

module "reverse-proxy" {
  source                   = "./modules/reverse_proxy"
  tls_secret_name          = var.tls_secret_name
  haos_homepage_token      = try(local.homepage_credentials["home_assistant"]["token"], "")
  opnsense_homepage_key    = data.vault_kv_secret_v2.opnsense.data["homepage_api_key"]
  opnsense_homepage_secret = data.vault_kv_secret_v2.opnsense.data["homepage_api_secret"]
}
