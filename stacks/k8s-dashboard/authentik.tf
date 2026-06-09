# -----------------------------------------------------------------------------
# Authentik OIDC application for the Kubernetes Dashboard (via oauth2-proxy).
#
# Confidential client `k8s-dashboard`. A custom scope mapping emits
# aud = ["kubernetes","k8s-dashboard"] so BOTH the kube-apiserver
# (--oidc-client-id=kubernetes) and oauth2-proxy (client_id=k8s-dashboard)
# accept the id_token. The existing UI-managed `kubernetes` public client
# used by the kubelogin CLI is untouched.
#
# Provider token: Vault secret/authentik -> tf_api_token (same as
# stacks/authentik/authentik_provider.tf).
# -----------------------------------------------------------------------------

data "vault_kv_secret_v2" "authentik_tf" {
  mount = "secret"
  name  = "authentik"
}

provider "authentik" {
  url   = "https://authentik.viktorbarzin.me"
  token = data.vault_kv_secret_v2.authentik_tf.data["tf_api_token"]
}

data "vault_kv_secret_v2" "k8s_dashboard" {
  mount = "secret"
  name  = "k8s-dashboard"
}

data "authentik_flow" "default_authorization_implicit_consent" {
  slug = "default-provider-authorization-implicit-consent"
}

data "authentik_flow" "default_provider_invalidation" {
  slug = "default-provider-invalidation-flow"
}

# RS256 signing keypair — REQUIRED, else Authentik signs the id_token with
# HS256 (client-secret HMAC) and publishes an EMPTY JWKS, so oauth2-proxy AND
# the apiserver fail signature verification ("failed to verify id token
# signature" / 500 on the OAuth callback). Same keypair the `kubernetes`
# provider uses.
data "authentik_certificate_key_pair" "signing" {
  name = "authentik Self-signed Certificate"
}

# Scope mappings — MIRROR the proven `kubernetes` provider exactly. Two are
# custom (no `managed` field) and are looked up by name:
#   * "Kubernetes Email (verified)" hardcodes `email_verified: true`. REQUIRED:
#     the apiserver rejects the email username-claim when email_verified is
#     false (Authentik external/social users are unverified), so the default
#     `scope-email` mapping (which passes through the real false) yields
#     "invalid bearer token" 401s. This custom mapping is why the CLI works.
#   * "Kubernetes Groups" emits the `groups` claim (scope_name=groups), so the
#     client must request the `groups` scope (see oauth2_proxy.tf).
# The token `aud` defaults to the client_id (`k8s-dashboard`), which the
# apiserver's k8s-dashboard issuer trusts — no custom audience mapping needed.
data "authentik_property_mapping_provider_scope" "openid" {
  managed = "goauthentik.io/providers/oauth2/scope-openid"
}
data "authentik_property_mapping_provider_scope" "profile" {
  managed = "goauthentik.io/providers/oauth2/scope-profile"
}
data "authentik_property_mapping_provider_scope" "email_verified" {
  name = "Kubernetes Email (verified)"
}
data "authentik_property_mapping_provider_scope" "groups" {
  name = "Kubernetes Groups"
}

resource "authentik_provider_oauth2" "k8s_dashboard" {
  name          = "k8s-dashboard"
  client_id     = data.vault_kv_secret_v2.k8s_dashboard.data["oauth2_proxy_client_id"]
  client_secret = data.vault_kv_secret_v2.k8s_dashboard.data["oauth2_proxy_client_secret"]
  client_type   = "confidential"

  authorization_flow = data.authentik_flow.default_authorization_implicit_consent.id
  invalidation_flow  = data.authentik_flow.default_provider_invalidation.id

  allowed_redirect_uris = [
    {
      matching_mode = "strict"
      url           = "https://k8s.viktorbarzin.me/oauth2/callback"
    },
  ]

  access_token_validity      = "hours=1"
  refresh_token_validity     = "days=30"
  include_claims_in_id_token = true
  signing_key                = data.authentik_certificate_key_pair.signing.id

  property_mappings = [
    data.authentik_property_mapping_provider_scope.openid.id,
    data.authentik_property_mapping_provider_scope.profile.id,
    data.authentik_property_mapping_provider_scope.email_verified.id,
    data.authentik_property_mapping_provider_scope.groups.id,
  ]
}

resource "authentik_application" "k8s_dashboard" {
  name               = "Kubernetes Dashboard"
  slug               = "k8s-dashboard"
  protocol_provider  = authentik_provider_oauth2.k8s_dashboard.id
  meta_launch_url    = "https://k8s.viktorbarzin.me"
  policy_engine_mode = "any"
}

# NO group-restriction policy: the kube-apiserver RBAC (per-user `User`
# bindings keyed on the OIDC email claim, from k8s_users in stacks/rbac) is the
# real, authoritative gate — exactly like the kubelogin CLI. Any Authentik user
# can complete the login, but only users with an RBAC binding can do anything
# (everyone else sees an empty/forbidden dashboard). A group gate here was
# both redundant with RBAC AND wrong: it gated on `kubernetes-*` group
# membership, but admins (e.g. vbarzin@gmail.com, in Home Server Admins) get
# cluster-admin via their email binding, not via those groups — so the gate
# locked out legitimate admins.
