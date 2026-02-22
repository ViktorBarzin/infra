variable "tls_secret_name" { type = string }
variable "immich_postgresql_password" { type = string }
variable "immich_frame_api_key" { type = string }
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

module "immich" {
  source = "../../modules/kubernetes/immich"
  tls_secret_name                = var.tls_secret_name
  postgresql_password            = var.immich_postgresql_password
  frame_api_key                  = var.immich_frame_api_key
  homepage_token                 = var.homepage_credentials["immich"]["token"]
  tier                           = local.tiers.gpu
}
