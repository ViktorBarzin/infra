variable "shadowsocks_password" { type = string }

locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

module "shadowsocks" {
  source = "./module"
  password                       = var.shadowsocks_password
  tier                           = local.tiers.edge
}
