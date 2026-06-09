variable "tls_secret_name" { type = string }
variable "k8s_ca_cert" {
  type    = string
  default = ""
}

module "k8s-portal" {
  source          = "./modules/k8s-portal"
  tier            = local.tiers.edge
  tls_secret_name = var.tls_secret_name
  k8s_ca_cert     = var.k8s_ca_cert
}
