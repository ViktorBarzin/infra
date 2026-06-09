variable "tls_secret_name" { type = string }
variable "nfs_server" { type = string }
variable "mail_host" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "platform"
}

module "vaultwarden" {
  source          = "./modules/vaultwarden"
  tls_secret_name = var.tls_secret_name
  mail_host       = var.mail_host
  smtp_password   = data.vault_kv_secret_v2.secrets.data["vaultwarden_smtp_password"]
  tier            = local.tiers.edge
  nfs_server      = var.nfs_server
}
