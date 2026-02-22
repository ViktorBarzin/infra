variable "tls_secret_name" { type = string }
variable "affine_postgresql_password" { type = string }
variable "mailserver_accounts" { type = map(any) }

locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

module "affine" {
  source              = "./module"
  tls_secret_name     = var.tls_secret_name
  postgresql_password = var.affine_postgresql_password
  smtp_password       = var.mailserver_accounts["info@viktorbarzin.me"]
  tier                = local.tiers.aux
}
