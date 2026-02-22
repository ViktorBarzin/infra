variable "tls_secret_name" { type = string }
variable "nextcloud_db_password" { type = string }

locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

module "nextcloud" {
  source = "./module"
  tls_secret_name                = var.tls_secret_name
  db_password                    = var.nextcloud_db_password
  tier                           = local.tiers.edge
}
