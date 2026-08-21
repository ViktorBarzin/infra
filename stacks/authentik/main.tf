# =============================================================================
# Authentik Stack — Identity provider (SSO)
# =============================================================================

variable "tls_secret_name" { type = string }
variable "redis_host" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "platform"
}

locals {
  homepage_credentials = jsondecode(data.vault_kv_secret_v2.secrets.data["homepage_credentials"])
}

module "authentik" {
  source            = "./modules/authentik"
  tier              = local.tiers.cluster
  tls_secret_name   = var.tls_secret_name
  secret_key        = data.vault_kv_secret_v2.secrets.data["authentik_secret_key"]
  postgres_password = data.vault_kv_secret_v2.secrets.data["authentik_postgres_password"]
  redis_host        = var.redis_host
  homepage_token    = try(local.homepage_credentials["authentik"]["token"], "")
}

# Re-apply 2026-08-21: pick up webmux.viktorbarzin.me. Per ADR-0023 the
# forward-auth host->groups table is rendered from the LIVE Ingress inventory
# at apply time, so a newly gated host stays denied (fail-safe) until this
# stack runs again. The webmux ingress landed in the previous commit; platform
# stacks apply before app stacks within one CI run, which is why this is a
# separate push rather than part of it.
