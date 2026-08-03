variable "tls_secret_name" { type = string }
variable "nfs_server" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "platform"
}

locals {
  homepage_credentials = jsondecode(data.vault_kv_secret_v2.secrets.data["homepage_credentials"])
}

module "headscale" {
  source             = "./modules/headscale"
  tls_secret_name    = var.tls_secret_name
  nfs_server         = var.nfs_server
  headscale_config   = data.vault_kv_secret_v2.secrets.data["headscale_config"]
  # ACL source of truth is acl.hujson in this directory, NOT Vault (moved
  # 2026-08-03). It is git-crypt encrypted because its group blocks carry family
  # email addresses and the GitHub mirror is public. Terraform reads it as
  # plaintext only from the main checkout — a worktree apply would render
  # ciphertext into the ConfigMap and break every client's policy. The stale
  # Vault field secret/platform.headscale_acl is retained read-only as a
  # break-glass copy; do not edit it.
  headscale_acl      = file("${path.module}/acl.hujson")
  headscale_derp_map = data.vault_kv_secret_v2.secrets.data["headscale_derp_map"]
  homepage_token     = try(local.homepage_credentials["headscale"]["api_key"], "")
  tier               = local.tiers.core
  ui_cookie_secret   = data.vault_kv_secret_v2.secrets.data["headscale_ui_cookie_secret"]
  ui_api_key         = data.vault_kv_secret_v2.secrets.data["headscale_ui_api_key"]
}
