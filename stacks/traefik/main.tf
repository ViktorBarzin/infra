variable "tls_secret_name" { type = string }
variable "redis_host" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "platform"
}

# x402 wallet lives under secret/viktor (Viktor's personal config) — not
# secret/platform — and is the only field this stack needs from there.
data "vault_kv_secret_v2" "viktor" {
  mount = "secret"
  name  = "viktor"
}

# Cloudflare Turnstile widget backing the CrowdSec captcha remediation. When
# LAPI issues a `captcha` decision (rate-limit / 403 / crawl / sensitive-file
# abuse — the captcha_remediation profile in stacks/crowdsec .../values.yaml),
# the Traefik bouncer plugin serves this widget so flagged users can
# self-unblock instead of getting a hard 403 (which is what happened before:
# the plugin had no captcha provider, so captcha decisions fell through to ban).
# Scoped to the registrable domain — a Turnstile hostname covers its subdomains,
# so one widget works on every *.viktorbarzin.me app the bouncer fronts.
# Same IaC pattern as stacks/forgejo/turnstile.tf; the CF Global API Key
# (cloudflare_provider.tf) has account-wide Turnstile access. The widget secret
# is sensitive and lands in TF state (Tier-1 PG, encrypted) — same trust level
# as the CrowdSec LAPI key already passed into the bouncer middleware.
data "cloudflare_accounts" "main" {}

resource "cloudflare_turnstile_widget" "crowdsec_captcha" {
  account_id = data.cloudflare_accounts.main.accounts[0].id
  name       = "crowdsec-captcha"
  domains    = ["viktorbarzin.me"]
  # "managed" = Cloudflare adaptively decides whether to show an interactive
  # challenge; lowest friction for real users, strong against bots.
  mode = "managed"
}

module "traefik" {
  source                 = "./modules/traefik"
  tier                   = local.tiers.core
  crowdsec_api_key       = data.vault_kv_secret_v2.secrets.data["ingress_crowdsec_api_key"]
  captcha_site_key       = cloudflare_turnstile_widget.crowdsec_captcha.id
  captcha_secret_key     = cloudflare_turnstile_widget.crowdsec_captcha.secret
  redis_host             = var.redis_host
  tls_secret_name        = var.tls_secret_name
  auth_fallback_htpasswd = data.vault_kv_secret_v2.secrets.data["auth_fallback_htpasswd"]
  x402_wallet_address    = lookup(data.vault_kv_secret_v2.viktor.data, "x402_wallet_address", "")
  # Reuses the existing Alertmanager Slack incoming webhook — same channel as
  # other infra alerts. Payment events arrive as a normal Slack message.
  x402_notify_webhook_url = lookup(data.vault_kv_secret_v2.viktor.data, "alertmanager_slack_api_url", "")
}
