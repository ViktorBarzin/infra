# -----------------------------------------------------------------------------
# The "Sign in with Google" source.
#
# Made by hand in the UI and adopted here on 2026-11-27 (import in imports.tf).
# Its client secret is not readable back from the API, so it was copied once
# from Authentik's database into Vault secret/authentik google_consumer_secret.
# The provider sends the secret on every update, so it must come from Vault:
# an empty value would blank it and stop every Google sign-in.
#
# user_matching_mode = "email_link": a Google sign-in whose email matches an
# existing account signs in to that account and links Google to it. GitHub and
# Facebook already match this way (still UI-managed). Before this, Google
# matched only by Google ID, so someone who had signed up with GitHub and then
# chose Google ran the enrollment flow and failed on the duplicate username
# (Kadir, 2026-11-27). Viktor chose one account per email address, whatever the
# sign-in method. The trade-off: whoever controls that address at Google gets
# the account, which GitHub and Facebook already allow for their users.
# -----------------------------------------------------------------------------
# The user-login-only flow every social sign-in runs (authentik_provider.tf).
data "authentik_flow" "default_source_authentication" {
  slug = "default-source-authentication"
}

resource "authentik_source_oauth" "google" {
  name          = "Google"
  slug          = "google"
  provider_type = "google"

  consumer_key    = "533122798643-ndhvdkti8lbq7e53qifh8etpofbbfcvm.apps.googleusercontent.com"
  consumer_secret = data.vault_kv_secret_v2.authentik_tf.data["google_consumer_secret"]

  authentication_flow = data.authentik_flow.default_source_authentication.id
  enrollment_flow     = authentik_flow.google_proxy_enrollment.uuid

  user_matching_mode = "email_link"

  authorization_url = "https://accounts.google.com/o/oauth2/v2/auth"
  access_token_url  = "https://oauth2.googleapis.com/token"
  profile_url       = "https://openidconnect.googleapis.com/v1/userinfo"
  oidc_jwks_url     = "https://www.googleapis.com/oauth2/v3/certs"

  lifecycle {
    # Authentik refreshes the keys from oidc_jwks_url itself. Ignoring them
    # makes every update send the live keys back instead of an empty set,
    # which the wrongmove provider's JWT federation reads.
    ignore_changes = [oidc_jwks]
  }
}
