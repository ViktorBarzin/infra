variable "tls_secret_name" { type = string }
variable "realestate_crawler_db_password" { type = string }
variable "realestate_crawler_notification_settings" { type = map(string) }

locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

module "real-estate-crawler" {
  source = "./module"
  tls_secret_name                = var.tls_secret_name
  db_password                    = var.realestate_crawler_db_password
  notification_settings          = var.realestate_crawler_notification_settings
  tier                           = local.tiers.aux
}
