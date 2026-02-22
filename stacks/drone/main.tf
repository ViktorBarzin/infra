variable "tls_secret_name" { type = string }
variable "drone_github_client_id" { type = string }
variable "drone_github_client_secret" { type = string }
variable "drone_rpc_secret" { type = string }
variable "drone_webhook_secret" { type = string }

locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

module "drone" {
  source               = "./module"
  tls_secret_name      = var.tls_secret_name
  git_crypt_key_base64 = filebase64("${path.root}/../../.git/git-crypt/keys/default")
  github_client_id     = var.drone_github_client_id
  github_client_secret = var.drone_github_client_secret
  rpc_secret           = var.drone_rpc_secret
  webhook_secret       = var.drone_webhook_secret
  server_host          = "drone.viktorbarzin.me"
  server_proto         = "https"
  tier                 = local.tiers.edge
}
