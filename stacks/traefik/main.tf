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

module "traefik" {
  source                 = "./modules/traefik"
  tier                   = local.tiers.core
  redis_host             = var.redis_host
  tls_secret_name        = var.tls_secret_name
  auth_fallback_htpasswd = data.vault_kv_secret_v2.secrets.data["auth_fallback_htpasswd"]
  x402_wallet_address    = lookup(data.vault_kv_secret_v2.viktor.data, "x402_wallet_address", "")
  # Reuses the existing Alertmanager Slack incoming webhook — same channel as
  # other infra alerts. Payment events arrive as a normal Slack message.
  x402_notify_webhook_url = lookup(data.vault_kv_secret_v2.viktor.data, "alertmanager_slack_api_url", "")
}
