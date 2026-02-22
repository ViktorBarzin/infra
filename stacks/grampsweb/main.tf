variable "tls_secret_name" { type = string }
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

module "grampsweb" {
  source = "../../modules/kubernetes/grampsweb"
  tls_secret_name                = var.tls_secret_name
  smtp_password                  = var.mailserver_accounts["info@viktorbarzin.me"]
  tier                           = local.tiers.aux
}
