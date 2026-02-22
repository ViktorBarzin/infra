variable "tls_secret_name" { type = string }
variable "actualbudget_credentials" { type = map(any) }

locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

module "actualbudget" {
  source          = "./module"
  tls_secret_name = var.tls_secret_name
  tier            = local.tiers.edge
  credentials     = var.actualbudget_credentials
}
