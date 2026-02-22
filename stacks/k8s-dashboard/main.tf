variable "tls_secret_name" { type = string }
variable "client_certificate_secret_name" { type = string }

locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

module "k8s-dashboard" {
  source = "../../modules/kubernetes/k8s-dashboard"
  tier                           = local.tiers.cluster
  tls_secret_name                = var.tls_secret_name
  client_certificate_secret_name = var.client_certificate_secret_name
}
