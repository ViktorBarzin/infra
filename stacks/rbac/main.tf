variable "tls_secret_name" { type = string }
variable "ssh_private_key" {
  type      = string
  default   = ""
  sensitive = true
}

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "platform"
}

locals {
  k8s_users = jsondecode(data.vault_kv_secret_v2.secrets.data["k8s_users"])
}

module "rbac" {
  source          = "./modules/rbac"
  tier            = local.tiers.cluster
  tls_secret_name = var.tls_secret_name
  k8s_users       = local.k8s_users
  ssh_private_key = var.ssh_private_key
}
