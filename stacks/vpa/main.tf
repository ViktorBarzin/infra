variable "tls_secret_name" { type = string }

module "vpa" {
  source          = "./modules/vpa"
  tls_secret_name = var.tls_secret_name
  tier            = local.tiers.cluster
}
