variable "tls_secret_name" { type = string }
variable "aiostreams_database_connection_string" { type = string }

locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

module "servarr" {
  source = "./module"
  tls_secret_name                = var.tls_secret_name
  tier                           = local.tiers.aux
  aiostreams_database_connection_string = var.aiostreams_database_connection_string
}
