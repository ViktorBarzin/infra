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

module "matrix" {
  source = "../../modules/kubernetes/matrix"
  tls_secret_name                = var.tls_secret_name
  tier                           = local.tiers.aux
}
