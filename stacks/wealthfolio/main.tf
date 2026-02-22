variable "tls_secret_name" { type = string }
variable "wealthfolio_password_hash" { type = string }

locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

module "wealthfolio" {
  source = "../../modules/kubernetes/wealthfolio"
  tls_secret_name                = var.tls_secret_name
  wealthfolio_password_hash      = var.wealthfolio_password_hash
  tier                           = local.tiers.aux
}
