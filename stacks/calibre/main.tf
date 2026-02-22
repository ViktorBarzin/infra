variable "tls_secret_name" { type = string }
variable "homepage_credentials" { type = map(any) }

locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

module "calibre" {
  source            = "./module"
  tls_secret_name   = var.tls_secret_name
  homepage_username = var.homepage_credentials["calibre-web"]["username"]
  homepage_password = var.homepage_credentials["calibre-web"]["password"]
  tier              = local.tiers.edge
}
