# =============================================================================
# DBaaS Stack — MySQL + PostgreSQL + pgAdmin
# =============================================================================

variable "tls_secret_name" { type = string }
variable "nfs_server" { type = string }
variable "prod" {
  type    = bool
  default = false
}

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "platform"
}

module "dbaas" {
  source                   = "./modules/dbaas"
  prod                     = var.prod
  tls_secret_name          = var.tls_secret_name
  nfs_server               = var.nfs_server
  dbaas_root_password      = data.vault_kv_secret_v2.secrets.data["dbaas_root_password"]
  postgresql_root_password = data.vault_kv_secret_v2.secrets.data["dbaas_postgresql_root_password"]
  pgadmin_password         = data.vault_kv_secret_v2.secrets.data["dbaas_pgadmin_password"]
  kube_config_path         = var.kube_config_path
  tier                     = local.tiers.cluster
}
