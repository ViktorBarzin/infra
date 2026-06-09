variable "tls_secret_name" { type = string }
variable "nfs_server" { type = string } # passed by config.tfvars, unused after NFS removal
variable "mysql_host" { type = string }
variable "postgresql_host" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "platform"
}

locals {
  homepage_credentials = jsondecode(data.vault_kv_secret_v2.secrets.data["homepage_credentials"])
}

module "technitium" {
  source              = "./modules/technitium"
  tls_secret_name     = var.tls_secret_name
  mysql_host          = var.mysql_host
  postgresql_host     = var.postgresql_host
  homepage_token      = local.homepage_credentials["technitium"]["token"]
  technitium_username = data.vault_kv_secret_v2.secrets.data["technitium_username"]
  technitium_password = data.vault_kv_secret_v2.secrets.data["technitium_password"]
  tier                = local.tiers.core
}
