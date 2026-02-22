variable "tls_secret_name" { type = string }
variable "url_shortener_geolite_license_key" { type = string }
variable "url_shortener_api_key" { type = string }
variable "url_shortener_mysql_password" { type = string }

locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

module "url" {
  source = "../../modules/kubernetes/url-shortener"
  tls_secret_name                = var.tls_secret_name
  geolite_license_key            = var.url_shortener_geolite_license_key
  api_key                        = var.url_shortener_api_key
  mysql_password                 = var.url_shortener_mysql_password
  tier                           = local.tiers.aux
}
