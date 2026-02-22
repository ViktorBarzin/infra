variable "tls_secret_name" { type = string }
variable "tandoor_database_password" { type = string }
variable "tandoor_email_password" {
  type    = string
  default = ""
}

locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

module "tandoor" {
  source = "../../modules/kubernetes/tandoor"
  tls_secret_name                = var.tls_secret_name
  tandoor_database_password      = var.tandoor_database_password
  tandoor_email_password         = var.tandoor_email_password
  tier                           = local.tiers.aux
}
