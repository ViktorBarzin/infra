variable "hackmd_db_password" { type = string }
variable "tls_secret_name" { type = string }

locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

module "hackmd" {
  source             = "./module"
  hackmd_db_password = var.hackmd_db_password
  tls_secret_name    = var.tls_secret_name
  tier               = local.tiers.edge
}
