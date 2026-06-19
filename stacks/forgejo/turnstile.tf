# Cloudflare Turnstile widget guarding the open Forgejo signup form
# (main.tf: FORGEJO__service__ENABLE_CAPTCHA + CAPTCHA_TYPE=cfturnstile).
# Managed here so the sitekey/secret are IaC rather than a dashboard artifact.
# The CF Global API Key (cloudflare_provider.tf) has account-wide access, so it
# can manage Turnstile. The widget secret is sensitive and lands in TF state
# (Tier-1 PG, encrypted at rest) — same trust level as the API key already in
# state. Forgejo is non-proxied, but Turnstile is a client-side JS widget served
# from challenges.cloudflare.com, so proxy status is irrelevant.
data "cloudflare_accounts" "main" {}

resource "cloudflare_turnstile_widget" "forgejo_signup" {
  account_id = data.cloudflare_accounts.main.accounts[0].id
  name       = "forgejo-signup"
  domains    = ["forgejo.viktorbarzin.me"]
  # "managed" = Cloudflare adaptively decides whether to show an interactive
  # challenge; lowest friction for real users, strong against bots.
  mode = "managed"
}

# Turnstile secret -> K8s Secret consumed by the Forgejo deployment via
# secret_key_ref (FORGEJO__service__CF_TURNSTILE_SECRET). The sitekey is public
# and passed as a plain env value in main.tf.
resource "kubernetes_secret" "forgejo_turnstile" {
  metadata {
    name      = "forgejo-turnstile"
    namespace = kubernetes_namespace.forgejo.metadata[0].name
  }
  data = {
    "cf-turnstile-secret" = cloudflare_turnstile_widget.forgejo_signup.secret
  }
}
