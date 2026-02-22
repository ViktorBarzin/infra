variable "tls_secret_name" { type = string }
variable "health_postgresql_password" { type = string }
variable "health_secret_key" { type = string }

locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

module "health" {
  source = "../../modules/kubernetes/health"
  tls_secret_name                = var.tls_secret_name
  postgresql_password            = var.health_postgresql_password
  secret_key                     = var.health_secret_key
  tier                           = local.tiers.aux
}
