variable "tls_secret_name" { type = string }
variable "clickhouse_password" { type = string }
variable "clickhouse_postgres_password" { type = string }

locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

module "rybbit" {
  source = "../../modules/kubernetes/rybbit"
  tls_secret_name                = var.tls_secret_name
  clickhouse_password            = var.clickhouse_password
  postgres_password              = var.clickhouse_postgres_password
  tier                           = local.tiers.aux
}
