variable "tls_secret_name" { type = string }
variable "resume_database_url" { type = string }
variable "resume_auth_secret" { type = string }
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

module "resume" {
  source = "../../modules/kubernetes/resume"
  tls_secret_name                = var.tls_secret_name
  tier                           = local.tiers.aux
  database_url                   = var.resume_database_url
  auth_secret                    = var.resume_auth_secret
  smtp_password                  = var.mailserver_accounts["info@viktorbarzin.me"]
}
