variable "tls_secret_name" { type = string }
variable "onlyoffice_db_password" { type = string }
variable "onlyoffice_jwt_token" { type = string }

locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

module "onlyoffice" {
  source = "../../modules/kubernetes/onlyoffice"
  tls_secret_name                = var.tls_secret_name
  db_password                    = var.onlyoffice_db_password
  jwt_token                      = var.onlyoffice_jwt_token
  tier                           = local.tiers.edge
}
