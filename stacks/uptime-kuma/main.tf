variable "tls_secret_name" { type = string }
variable "nfs_server" { type = string }
variable "cloudflare_proxied_names" { type = list(string) }

module "uptime-kuma" {
  source                   = "./modules/uptime-kuma"
  tls_secret_name          = var.tls_secret_name
  nfs_server               = var.nfs_server
  tier                     = local.tiers.cluster
  cloudflare_proxied_names = var.cloudflare_proxied_names
}
