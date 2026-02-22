variable "tls_secret_name" { type = string }
variable "n8n_postgresql_password" { type = string }

locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

module "n8n" {
  source = "./module"
  tls_secret_name                = var.tls_secret_name
  postgresql_password            = var.n8n_postgresql_password
  tier                           = local.tiers.aux
}
