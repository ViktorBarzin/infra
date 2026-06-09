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

# Personal/app-user secrets (forgejo + roundcubemail MySQL passwords live here,
# not under secret/platform, to match the "secret/viktor as the go-to personal
# vault" convention documented in .claude/CLAUDE.md).
data "vault_kv_secret_v2" "viktor" {
  mount = "secret"
  name  = "viktor"
}

module "dbaas" {
  source                       = "./modules/dbaas"
  prod                         = var.prod
  tls_secret_name              = var.tls_secret_name
  nfs_server                   = var.nfs_server
  dbaas_root_password          = data.vault_kv_secret_v2.secrets.data["dbaas_root_password"]
  postgresql_root_password     = data.vault_kv_secret_v2.secrets.data["dbaas_postgresql_root_password"]
  pgadmin_password             = data.vault_kv_secret_v2.secrets.data["dbaas_pgadmin_password"]
  mysql_forgejo_password       = data.vault_kv_secret_v2.viktor.data["mysql_forgejo_password"]
  mysql_roundcubemail_password = data.vault_kv_secret_v2.viktor.data["mysql_roundcubemail_password"]
  kube_config_path             = var.kube_config_path
  tier                         = local.tiers.cluster
}
