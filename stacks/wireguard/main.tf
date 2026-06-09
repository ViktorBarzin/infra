variable "tls_secret_name" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "platform"
}

module "wireguard" {
  source          = "./modules/wireguard"
  tls_secret_name = var.tls_secret_name
  wg_0_conf       = data.vault_kv_secret_v2.secrets.data["wireguard_wg_0_conf"]
  wg_0_key        = data.vault_kv_secret_v2.secrets.data["wireguard_wg_0_key"]
  firewall_sh     = data.vault_kv_secret_v2.secrets.data["wireguard_firewall_sh"]
  tier            = local.tiers.core
}
