variable "tls_secret_name" { type = string }
variable "diun_nfty_token" { type = string }
variable "diun_slack_url" { type = string }

locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

module "diun" {
  source = "../../modules/kubernetes/diun"
  tls_secret_name                = var.tls_secret_name
  diun_nfty_token                = var.diun_nfty_token
  diun_slack_url                 = var.diun_slack_url
  tier                           = local.tiers.aux
}
