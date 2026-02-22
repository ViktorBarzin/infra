variable "tls_secret_name" { type = string }
variable "ollama_api_credentials" { type = map(string) }

locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

module "ollama" {
  source = "./module"
  tls_secret_name                = var.tls_secret_name
  tier                           = local.tiers.gpu
  ollama_api_credentials         = var.ollama_api_credentials
}
