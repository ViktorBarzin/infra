variable "tls_secret_name" { type = string }
variable "openrouter_api_key" { type = string }
variable "slack_bot_token" { type = string }
variable "slack_channel" { type = string }

locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

module "ytdlp" {
  source = "./module"
  tls_secret_name                = var.tls_secret_name
  tier                           = local.tiers.aux
  openrouter_api_key             = var.openrouter_api_key
  slack_bot_token                = var.slack_bot_token
  slack_channel                  = var.slack_channel
}
