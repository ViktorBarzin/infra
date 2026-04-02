variable "nfs_server" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "viktor"
}

module "proxmox-csi" {
  source               = "./modules/proxmox-csi"
  tier                 = local.tiers.cluster
  proxmox_url          = "https://192.168.1.127:8006/api2/json"
  proxmox_token_id     = data.vault_kv_secret_v2.secrets.data["proxmox_csi_token_id"]
  proxmox_token_secret = data.vault_kv_secret_v2.secrets.data["proxmox_csi_token_secret"]
  proxmox_cluster_name = "pve"
  kube_config_path     = var.kube_config_path
}
