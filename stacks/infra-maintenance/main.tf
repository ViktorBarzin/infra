variable "nfs_server" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "platform"
}

module "infra-maintenance" {
  source              = "./modules/infra-maintenance"
  nfs_server          = var.nfs_server
  git_user            = data.vault_kv_secret_v2.secrets.data["webhook_handler_git_user"]
  git_token           = data.vault_kv_secret_v2.secrets.data["webhook_handler_git_token"]
  technitium_username = data.vault_kv_secret_v2.secrets.data["technitium_username"]
  technitium_password = data.vault_kv_secret_v2.secrets.data["technitium_password"]
}
