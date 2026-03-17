variable "nfs_server" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "platform"
}

module "iscsi-csi" {
  source                  = "./modules/iscsi-csi"
  tier                    = local.tiers.cluster
  truenas_host            = var.nfs_server
  truenas_api_key         = data.vault_kv_secret_v2.secrets.data["truenas_api_key"]
  truenas_ssh_private_key = data.vault_kv_secret_v2.secrets.data["truenas_ssh_private_key"]
}
