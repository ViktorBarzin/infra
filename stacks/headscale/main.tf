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
  source          = "./modules/headscale"
  tls_secret_name = var.tls_secret_name
  nfs_server      = var.nfs_server
  # SPLIT DNS: dns.nameservers.split inside this Vault value must carry BOTH
  # viktorbarzin.lan AND viktorbarzin.me, each pointing at Technitium
  # 10.0.20.201 (added 2026-08-31, Vault v58).
  #
  # Without the .me entry a tailnet client resolves it with the global public
  # nameservers, which answer every non-Cloudflare-proxied host with our own
  # WAN address 176.12.22.76. The client then has to hairpin off that public
  # IP, and NAT loopback on the CPE in front of pfSense does not reliably do
  # it. The failure is partial and therefore confusing: Cloudflare-proxied
  # hosts keep working because their traffic genuinely leaves and returns,
  # while directly-served ones hang. Technitium holds the split-horizon view
  # returning Traefik on 10.0.20.203, so tailnet clients resolve internally
  # and the hairpin disappears.
  #
  # The config lives in Vault, so none of this is visible in the repo.
  headscale_config = data.vault_kv_secret_v2.secrets.data["headscale_config"]
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
