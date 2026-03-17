variable "tls_secret_name" { type = string }
variable "nfs_server" { type = string }

module "redis" {
  source          = "./modules/redis"
  tls_secret_name = var.tls_secret_name
  nfs_server      = var.nfs_server
  tier            = local.tiers.cluster
}
