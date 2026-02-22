variable "tls_secret_name" { type = string }
variable "paperless_db_password" { type = string }
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

module "paperless-ngx" {
  source = "../../modules/kubernetes/paperless-ngx"
  tls_secret_name                = var.tls_secret_name
  db_password                    = var.paperless_db_password
  homepage_username              = var.homepage_credentials["paperless-ngx"]["username"]
  homepage_password              = var.homepage_credentials["paperless-ngx"]["password"]
  tier                           = local.tiers.edge
}
