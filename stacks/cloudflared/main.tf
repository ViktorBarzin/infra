# =============================================================================
# Cloudflared Stack — Cloudflare tunnel + DNS records
# =============================================================================

variable "tls_secret_name" { type = string }
variable "cloudflare_email" { type = string }
variable "cloudflare_account_id" { type = string }
variable "cloudflare_zone_id" { type = string }
variable "cloudflare_tunnel_id" { type = string }
variable "public_ip" { type = string }
variable "public_ipv6" { type = string }
variable "cloudflare_proxied_names" {}
variable "cloudflare_non_proxied_names" {}

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "platform"
}

locals {
  k8s_users = jsondecode(data.vault_kv_secret_v2.secrets.data["k8s_users"])

  user_domains = flatten([
    for name, user in local.k8s_users : lookup(user, "domains", [])
    if user.role == "namespace-owner"
  ])
}

module "cloudflared" {
  source          = "./modules/cloudflared"
  tier            = local.tiers.core
  tls_secret_name = var.tls_secret_name

  cloudflare_api_key           = data.vault_kv_secret_v2.secrets.data["cloudflare_api_key"]
  cloudflare_email             = var.cloudflare_email
  cloudflare_account_id        = var.cloudflare_account_id
  cloudflare_zone_id           = var.cloudflare_zone_id
  cloudflare_tunnel_id         = var.cloudflare_tunnel_id
  public_ip                    = var.public_ip
  public_ipv6                  = var.public_ipv6
  cloudflare_proxied_names     = concat(var.cloudflare_proxied_names, nonsensitive(local.user_domains))
  cloudflare_non_proxied_names = var.cloudflare_non_proxied_names
  cloudflare_tunnel_token      = data.vault_kv_secret_v2.secrets.data["cloudflare_tunnel_token"]
}
