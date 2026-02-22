variable "tls_secret_name" { type = string }
variable "coturn_turn_secret" { type = string }
variable "public_ip" { type = string }

locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

module "f1-stream" {
  source          = "./module"
  tls_secret_name = var.tls_secret_name
  tier            = local.tiers.aux
  turn_secret     = var.coturn_turn_secret
  public_ip       = var.public_ip
}
