variable "tls_secret_name" { type = string }
variable "webhook_handler_secret" { type = string }
variable "webhook_handler_fb_verify_token" { type = string }
variable "webhook_handler_fb_page_token" { type = string }
variable "webhook_handler_fb_app_secret" { type = string }
variable "webhook_handler_git_user" { type = string }
variable "webhook_handler_git_token" { type = string }
variable "webhook_handler_ssh_key" { type = string }

locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

module "webhook_handler" {
  source = "../../modules/kubernetes/webhook_handler"
  tls_secret_name                = var.tls_secret_name
  webhook_secret                 = var.webhook_handler_secret
  fb_verify_token                = var.webhook_handler_fb_verify_token
  fb_page_token                  = var.webhook_handler_fb_page_token
  fb_app_secret                  = var.webhook_handler_fb_app_secret
  git_user                       = var.webhook_handler_git_user
  git_token                      = var.webhook_handler_git_token
  ssh_key                        = var.webhook_handler_ssh_key
  tier                           = local.tiers.aux
}
