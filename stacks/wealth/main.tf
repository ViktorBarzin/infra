variable "image_tag" {
  type        = string
  default     = "latest"
  description = "Image tag used when the Deployment is (re)created. The running tag is set by the Woodpecker deploy (kubectl set image)."
}

variable "postgresql_host" { type = string }

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

# Wealth: a personal-finance planner for a few households, with actuals from
# broker connectors and lifetime plans (Forgejo viktor/wealth, private; build
# spec in that repo at docs/spec.md). It replaces fire-planner at go-live.
#
# secret/wealth in Vault KV holds better_auth_secret, oidc_client_id and
# oidc_client_secret (seeded by hand on 2026-11-24), and
# connector_secrets_key: 32 random bytes, base64, the AES-256-GCM key that
# encrypts the connector secrets members paste in (broker tokens, API keys,
# IMAP passwords) before the app stores them in its database. The `wealth`
# database and the Vault static role pg-wealth come from the dbaas
# app_databases and vault pg_app_roles maps.
module "app" {
  source = "../../modules/kubernetes/tanstack_app"

  name         = "wealth"
  display_name = "Wealth"
  tier         = local.tiers.aux

  # Private repo, private ghcr package: Kyverno clones ghcr-credentials into
  # this namespace (stacks/kyverno ghcr_private_namespaces).
  image              = "ghcr.io/viktorbarzin/wealth"
  image_tag          = var.image_tag
  image_pull_secrets = ["ghcr-credentials"]

  postgresql_host = var.postgresql_host
  tls_secret_name = var.tls_secret_name

  app_secret_env = { CONNECTOR_SECRETS_KEY = "connector_secrets_key" }

  # Viktor signs in as a member and approves everyone else. Request mode
  # refuses to plan without an admin.
  initial_user_pks = [data.authentik_user.viktor.id]
  admin_user_pks   = [data.authentik_user.viktor.id]

  ingress = {
    homepage_description = "Household net worth, investments and lifetime financial plans"
    homepage_icon        = "mdi-finance"
    homepage_group       = "Finance & Personal"
  }
}
