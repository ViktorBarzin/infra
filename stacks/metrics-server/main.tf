variable "tls_secret_name" { type = string }

module "metrics-server" {
  source          = "./modules/metrics-server"
  tier            = local.tiers.cluster
  tls_secret_name = var.tls_secret_name
}
