variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }

module "postiz" {
  source              = "./modules/postiz"
  tls_secret_name     = var.tls_secret_name
  tier                = local.tiers.aux
  oauth_client_secret = authentik_provider_oauth2.postiz.client_secret
}
