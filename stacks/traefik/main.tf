variable "tls_secret_name" { type = string }
variable "redis_host" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "platform"
}

module "traefik" {
  source                 = "./modules/traefik"
  tier                   = local.tiers.core
  crowdsec_api_key       = data.vault_kv_secret_v2.secrets.data["ingress_crowdsec_api_key"]
  redis_host             = var.redis_host
  tls_secret_name        = var.tls_secret_name
  auth_fallback_htpasswd = data.vault_kv_secret_v2.secrets.data["auth_fallback_htpasswd"]
}
