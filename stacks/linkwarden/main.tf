variable "tls_secret_name" { type = string }
variable "linkwarden_postgresql_password" { type = string }
variable "linkwarden_authentik_client_id" { type = string }
variable "linkwarden_authentik_client_secret" { type = string }

locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

module "linkwarden" {
  source = "../../modules/kubernetes/linkwarden"
  tls_secret_name                = var.tls_secret_name
  postgresql_password            = var.linkwarden_postgresql_password
  authentik_client_id            = var.linkwarden_authentik_client_id
  authentik_client_secret        = var.linkwarden_authentik_client_secret
  tier                           = local.tiers.aux
}
