# -----------------------------------------------------------------------------
# Authentik OIDC identities for the Kubernetes API.
#
# Two identities, one per actor kind, both pointed at the same kube-apiserver:
#
#   `kubernetes`        the human CLI client. Live and in daily use by kubelogin
#                       (scripts/t3-provision-users.sh writes every user's
#                       kubeconfig against it). Created in the Authentik UI in
#                       Feb 2026, so Terraform does not own it yet — the
#                       resources below describe it exactly as it runs and are
#                       adopted via the `import` blocks, gated OFF by default.
#
#   `kubernetes-agent`  new. Same Authentik users, same groups, but a separate
#                       issuer whose claims the apiserver maps under the
#                       `agent:` prefix. That prefix is the whole point: it puts
#                       "an agent did this" in `user.username` on every audit
#                       event, and it keeps agent sessions out of every human
#                       RBAC binding (an agent carrying Viktor's groups arrives
#                       as `agent:kubernetes-admins`, never `kubernetes-admins`).
#
# WHY a separate issuer rather than a second client on the same one: the audit
# event records `user.username`, `user.groups` and `user.extra`, and NOT the
# issuer. Two clients on one issuer would both mint `vbarzin@gmail.com` and the
# audit log could not tell them apart. The username prefix is per-issuer in
# AuthenticationConfiguration, so a separate issuer is what makes the
# distinction land in the log.
#
# `authentication.kubernetes.io/credential-id` then adds session granularity on
# top: measured 2026-09-01, a JWT-authenticated request records `JTI=<uuid>`
# (one value per token) while every cert-authenticated request records
# `X509SHA256=<fingerprint>` — one shared value for every human, agent and cron
# job using the kubeadm admin cert.
#
# NOTHING HERE MAKES THE APISERVER TRUST THE AGENT ISSUER. That is a separate,
# deliberate, human step: `agent_oidc_enabled` in modules/rbac/apiserver-oidc.tf,
# performed per docs/runbooks/apiserver-oidc-agent-identity.md. Applying this
# file only creates an Authentik application that no issuer list mentions yet.
# -----------------------------------------------------------------------------

data "vault_kv_secret_v2" "authentik_tf" {
  mount = "secret"
  name  = "authentik"
}

provider "authentik" {
  url   = "https://authentik.viktorbarzin.me"
  token = data.vault_kv_secret_v2.authentik_tf.data["tf_api_token"]
}

# --- Shared references (all four already exist; none is created here) --------

data "authentik_flow" "default_authorization_implicit_consent" {
  slug = "default-provider-authorization-implicit-consent"
}

data "authentik_flow" "default_provider_invalidation" {
  slug = "default-provider-invalidation-flow"
}

# RS256 signing keypair. REQUIRED: without it Authentik signs the id_token with
# HS256 (client-secret HMAC) and publishes an empty JWKS, and the apiserver
# cannot verify the signature. Same keypair the live `kubernetes` provider uses.
data "authentik_certificate_key_pair" "signing" {
  name = "authentik Self-signed Certificate"
}

# Scope mappings. Two are custom and looked up by name:
#   * "Kubernetes Email (verified)" returns `email_verified: true` unconditionally.
#     Needed because the apiserver rejects an email username-claim when
#     email_verified is false, which is the case for every Authentik
#     external/social user.
#   * "Kubernetes Groups" emits `groups` verbatim from Authentik group names
#     (`[group.name for group in request.user.ak_groups.all()]`), which is what
#     makes the group-keyed RBAC in modules/rbac/oidc-group-bindings.tf work.
#     scope_name is `groups`, so the client must request the `groups` scope —
#     every provisioned kubeconfig passes `--oidc-extra-scope=groups`.
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

# kubelogin drives the PKCE loopback flow, so both clients are public (no
# secret) and both accept only a loopback redirect on an arbitrary port.
locals {
  kubelogin_redirect_uris = [
    {
      matching_mode = "regex"
      url           = "http://localhost:.*"
    },
    {
      matching_mode = "regex"
      url           = "http://127\\.0\\.0\\.1:.*"
    },
  ]
}

# --- The human CLI client: describe-and-adopt, gated off ---------------------

variable "manage_kubernetes_oidc_app" {
  type        = bool
  default     = false
  description = <<-DESC
    Bring the live, UI-created `kubernetes` OIDC provider and application under
    Terraform. Default false so a plain apply touches neither: this client is
    what every human's kubectl authenticates with, and a field this config got
    wrong would be written back to it.

    Adoption is a two-command human step, not something to flip and push. Set it
    true, run a plan, confirm the plan is import-only with zero changes, then
    apply. Procedure: docs/runbooks/apiserver-oidc-agent-identity.md.
  DESC
}

locals {
  # Empty set => resources absent and import blocks inert.
  adopt_kubernetes_app = var.manage_kubernetes_oidc_app ? toset(["kubernetes"]) : toset([])
}

# Field-for-field the live provider, read from the Authentik API on 2026-09-01
# (provider pk 19). Change nothing here without knowing why: a diff on apply is
# a change to the credential path every human uses to reach the cluster.
resource "authentik_provider_oauth2" "kubernetes" {
  for_each = local.adopt_kubernetes_app

  name        = "kubernetes"
  client_id   = "kubernetes"
  client_type = "public"

  authorization_flow = data.authentik_flow.default_authorization_implicit_consent.id
  invalidation_flow  = data.authentik_flow.default_provider_invalidation.id

  access_code_validity       = "minutes=1"
  access_token_validity      = "hours=1"
  refresh_token_validity     = "days=30"
  include_claims_in_id_token = true
  signing_key                = data.authentik_certificate_key_pair.signing.id
  sub_mode                   = "user_email"
  issuer_mode                = "per_provider"

  allowed_redirect_uris = local.kubelogin_redirect_uris

  # Order matches the live provider, so adoption plans to zero.
  property_mappings = [
    data.authentik_property_mapping_provider_scope.groups.id,
    data.authentik_property_mapping_provider_scope.email_verified.id,
    data.authentik_property_mapping_provider_scope.openid.id,
    data.authentik_property_mapping_provider_scope.profile.id,
  ]
}

resource "authentik_application" "kubernetes" {
  for_each = local.adopt_kubernetes_app

  name               = "Kubernetes"
  slug               = "kubernetes"
  protocol_provider  = authentik_provider_oauth2.kubernetes[each.key].id
  meta_launch_url    = "https://k8s-portal.viktorbarzin.me"
  policy_engine_mode = "any"
}

# Adoption stanzas. Inert while `manage_kubernetes_oidc_app` is false; remove
# both once the import has landed, per AGENTS.md -> "Adopting Existing
# Resources". IDs are the live primary keys (provider pk, application slug).
import {
  for_each = local.adopt_kubernetes_app
  to       = authentik_provider_oauth2.kubernetes[each.key]
  id       = "19"
}

import {
  for_each = local.adopt_kubernetes_app
  to       = authentik_application.kubernetes[each.key]
  id       = "kubernetes"
}

# --- The agent client: new, created on apply --------------------------------
#
# Created unconditionally, because creating it changes nothing: no issuer list
# names it, so a token it mints is rejected by the apiserver as an untrusted
# issuer until a human enables the third issuer per the runbook. Landing it
# first is deliberate — it lets the token path be tested end to end (mint a
# token, decode it, check `email`/`groups`/`aud`) before the control plane is
# touched at all.

resource "authentik_provider_oauth2" "kubernetes_agent" {
  name        = "kubernetes-agent"
  client_id   = "kubernetes-agent"
  client_type = "public"

  authorization_flow = data.authentik_flow.default_authorization_implicit_consent.id
  invalidation_flow  = data.authentik_flow.default_provider_invalidation.id

  access_code_validity  = "minutes=1"
  access_token_validity = "hours=1"

  # Parity with the human client. This is the knob that decides how often a
  # human has to re-authorise an unattended agent: 30 days means an agent's
  # refresh token is a standing credential for a month, and the RBAC in
  # modules/rbac/oidc-group-bindings.tf is what bounds what a leaked one can do
  # (cluster-wide read, no Secrets, no exec). Shortening it here is safe and
  # costs one interactive login per window. Genuinely short-lived per-session
  # credentials are step 5 of the design, via the Vault Kubernetes engine.
  refresh_token_validity = "days=30"

  include_claims_in_id_token = true
  signing_key                = data.authentik_certificate_key_pair.signing.id
  sub_mode                   = "user_email"
  issuer_mode                = "per_provider"

  allowed_redirect_uris = local.kubelogin_redirect_uris

  # Same four mappings as the human client. The `agent:` prefix that separates
  # the two is applied by the apiserver, not here — Authentik emits the plain
  # email and group names for both clients.
  property_mappings = [
    data.authentik_property_mapping_provider_scope.groups.id,
    data.authentik_property_mapping_provider_scope.email_verified.id,
    data.authentik_property_mapping_provider_scope.openid.id,
    data.authentik_property_mapping_provider_scope.profile.id,
  ]
}

resource "authentik_application" "kubernetes_agent" {
  name = "Kubernetes (agent sessions)"

  # The slug IS the issuer path: https://authentik.viktorbarzin.me/application/o/<slug>/
  # It has to match `agent_oidc_issuer_url` in modules/rbac/apiserver-oidc.tf.
  slug = "kubernetes-agent"

  protocol_provider  = authentik_provider_oauth2.kubernetes_agent.id
  policy_engine_mode = "any"

  meta_description = "Agent sessions reaching the Kubernetes API. Claims arrive at the apiserver under the agent: prefix."

  # Authentik's idiom for "not launchable" — keeps a credential-only client out
  # of the user library, where a launch tile would only mislead.
  meta_launch_url = "blank://blank"
}

# No group-restriction policy on either application, matching the reasoning in
# stacks/k8s-dashboard/authentik.tf: RBAC is the authoritative gate. Any
# Authentik user can complete the login and get a token; a user with no
# matching binding can do nothing with it. A policy here would be a second,
# quieter gate that fails in a way nobody can read off an audit event.

locals {
  # The apiserver compares `iss` as an exact string, trailing slash included, so
  # derive it from the application slug rather than restating the URL.
  kubernetes_agent_issuer_url = "https://authentik.viktorbarzin.me/application/o/${authentik_application.kubernetes_agent.slug}/"
}

output "kubernetes_agent_issuer_url" {
  description = "Issuer URL the apiserver must trust for agent sessions."
  value       = local.kubernetes_agent_issuer_url
}
