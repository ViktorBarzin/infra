variable "tls_secret_name" { type = string }
variable "speedtest_db_password" { type = string }

locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

module "speedtest" {
  source = "../../modules/kubernetes/speedtest"
  tls_secret_name                = var.tls_secret_name
  tier                           = local.tiers.aux
  db_password                    = var.speedtest_db_password
}
