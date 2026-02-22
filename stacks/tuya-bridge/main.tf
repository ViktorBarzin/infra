variable "tls_secret_name" { type = string }
variable "tiny_tuya_api_key" { type = string }
variable "tiny_tuya_api_secret" { type = string }
variable "tiny_tuya_service_secret" { type = string }
variable "tiny_tuya_slack_url" { type = string }

locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

module "tuya-bridge" {
  source = "../../modules/kubernetes/tuya-bridge"
  tls_secret_name                = var.tls_secret_name
  tier                           = local.tiers.cluster
  tiny_tuya_api_key              = var.tiny_tuya_api_key
  tiny_tuya_api_secret           = var.tiny_tuya_api_secret
  tiny_tuya_service_secret       = var.tiny_tuya_service_secret
  slack_url                      = var.tiny_tuya_slack_url
}
