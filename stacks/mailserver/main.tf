# =============================================================================
# Mailserver Stack — docker-mailserver
# =============================================================================

variable "tls_secret_name" { type = string }
variable "nfs_server" { type = string }
variable "mysql_host" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "platform"
}

locals {
  mailserver_accounts     = jsondecode(data.vault_kv_secret_v2.secrets.data["mailserver_accounts"])
  mailserver_aliases      = jsondecode(data.vault_kv_secret_v2.secrets.data["mailserver_aliases"])
  mailserver_opendkim_key = jsondecode(data.vault_kv_secret_v2.secrets.data["mailserver_opendkim_key"])
  mailserver_sasl_passwd  = jsondecode(data.vault_kv_secret_v2.secrets.data["mailserver_sasl_passwd"])
}

module "mailserver" {
  source                  = "./modules/mailserver"
  tls_secret_name         = var.tls_secret_name
  nfs_server              = var.nfs_server
  mysql_host              = var.mysql_host
  mailserver_accounts     = local.mailserver_accounts
  postfix_account_aliases = local.mailserver_aliases
  opendkim_key            = local.mailserver_opendkim_key
  sasl_passwd             = local.mailserver_sasl_passwd
  roundcube_db_password   = data.vault_kv_secret_v2.secrets.data["mailserver_roundcubemail_db_password"]
  tier                    = local.tiers.edge
}
