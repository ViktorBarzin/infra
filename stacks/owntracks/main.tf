variable "tls_secret_name" { type = string }
variable "owntracks_credentials" { type = map(string) }

locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

module "owntracks" {
  source = "../../modules/kubernetes/owntracks"
  tls_secret_name                = var.tls_secret_name
  owntracks_credentials          = var.owntracks_credentials
  tier                           = local.tiers.aux
}
