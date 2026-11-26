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
# spec in that repo at docs/spec.md). It replaced fire-planner, which retired
# on 2026-11-26.
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

  # The Fidelity connector in wealth-worker drives chrome-service over CDP
  # (jobs.tf, FIDELITY_CDP_URL). chrome-service's NetworkPolicy admits it by
  # namespace name and pod label, so this namespace carries no client label:
  # the web and engine pods get no CDP access.

  postgresql_host = var.postgresql_host
  tls_secret_name = var.tls_secret_name

  app_secret_env = { CONNECTOR_SECRETS_KEY = "connector_secrets_key" }

  # A household restore is one request of up to 32 MiB (the app's
  # RESTORE_BODY_LIMIT, src/start.ts). A 10 MB backup, 16 MB on the wire,
  # took the web process from 69 to 229 MiB, so the 256Mi default would be
  # OOM-killed near the cap (council review, wealth phase 4). Idle is about
  # 90 MiB.
  resources = {
    requests = { cpu = "50m", memory = "128Mi" }
    limits   = { memory = "768Mi" }
  }

  # Viktor signs in as a member and approves everyone else. Request mode
  # refuses to plan without an admin.
  initial_user_pks = [data.authentik_user.viktor.id]
  admin_user_pks   = [data.authentik_user.viktor.id]

  ingress = {
    homepage_description = "Household net worth, investments and lifetime financial plans"
    homepage_icon        = "mdi-finance"
    homepage_group       = "Finance & Personal"
    # A cold Plan page makes about 60 requests, about 51 of them hashed JS
    # chunks in the first 400 ms. That is over the default burst of 50, and
    # a 429 on the engine worker's script stopped the page's Monte Carlo
    # (2026-11-25). 100/1000 is the level of the other SPA carve-outs.
    rate_limit = { average = 100, burst = 1000 }
  }
}
