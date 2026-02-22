variable "tls_secret_name" { type = string }
variable "dawarich_database_password" { type = string }
variable "geoapify_api_key" { type = string }

locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

module "dawarich" {
  source            = "./module"
  tls_secret_name   = var.tls_secret_name
  database_password = var.dawarich_database_password
  geoapify_api_key  = var.geoapify_api_key
  tier              = local.tiers.edge
}
