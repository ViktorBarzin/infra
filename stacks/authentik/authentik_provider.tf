# goauthentik/authentik Terraform provider.
#
# Adopted 2026-04-18 (Wave 6a of the state-drift consolidation plan) to bring
# the catch-all Proxy Provider — previously managed only via the Authentik UI
# — under Terraform management. API token lives in Vault
# `secret/authentik/tf_api_token` (token identifier `terraform-infra-stack`,
# intent API, user akadmin, no expiry). Required-providers declaration sits
# in the central terragrunt.hcl so every stack has it available; only this
# stack configures a provider block.

data "vault_kv_secret_v2" "authentik_tf" {
  mount = "secret"
  name  = "authentik"
}

provider "authentik" {
  url   = "https://authentik.viktorbarzin.me"
  token = data.vault_kv_secret_v2.authentik_tf.data["tf_api_token"]
}

data "authentik_flow" "default_authorization_implicit_consent" {
  slug = "default-provider-authorization-implicit-consent"
}

data "authentik_flow" "default_provider_invalidation" {
  slug = "default-provider-invalidation-flow"
}

# -----------------------------------------------------------------------------
# Catch-all Proxy Provider + Application.
#
# Created via the Authentik UI ~a year ago; adopted into Terraform 2026-04-18
# (Wave 6a). The proxy provider is consumed by the embedded outpost
# (uuid 0eecac07-97c7-443c-8925-05f2f4fe3e47) via an outpost-level binding
# that stays in the UI — it's a single toggle with no drift risk.
# -----------------------------------------------------------------------------

resource "authentik_application" "catchall" {
  name              = "Domain wide catch all"
  slug              = "domain-wide-catch-all"
  protocol_provider = authentik_provider_proxy.catchall.id
  lifecycle {
    ignore_changes = [meta_description, meta_launch_url, meta_icon, group, backchannel_providers, policy_engine_mode, open_in_new_tab]
  }
}

resource "authentik_provider_proxy" "catchall" {
  name          = "Provider for Domain wide catch all"
  mode          = "forward_domain"
  external_host = "https://authentik.viktorbarzin.me"
  cookie_domain = "viktorbarzin.me"
  # Flow UUIDs resolved dynamically so a flow re-creation (keeping the slug)
  # doesn't require an HCL edit.
  authorization_flow = data.authentik_flow.default_authorization_implicit_consent.id
  invalidation_flow  = data.authentik_flow.default_provider_invalidation.id
  # Cookie / proxysession TTL. Drives `Max-Age` on `authentik_proxy_*`
  # cookies and the `expires` column in `authentik_providers_proxy_proxysession`.
  # See note on the embedded outpost below — bumping this requires an outpost
  # pod restart for the gorilla session store to rebind.
  access_token_validity = "weeks=4"
  lifecycle {
    ignore_changes = [property_mappings, jwt_federation_sources, skip_path_regex, internal_host, basic_auth_enabled, basic_auth_password_attribute, basic_auth_username_attribute, intercept_header_auth]
  }
}

# -----------------------------------------------------------------------------
# Embedded outpost record. Adopted into Terraform 2026-05-10 as part of the
# postgres-session-backend fix:
#   - `managed` is set server-side to `goauthentik.io/outposts/embedded` so
#     the outpost binary's `IsEmbedded()` check returns true → it loads the
#     PostgreSQL session backend (PR #16628). The Terraform provider does
#     NOT expose `managed` in the schema, so the field is preserved across
#     applies (TF only writes fields it knows about).
#
# Since 2026-09-19 this outpost has NO pods and NO Kubernetes objects of its
# own. Forward-auth is served by the inline outpost inside the goauthentik-server
# pods, and we own the Service that points at them (bead code-osvg). The
# `service` and `ingress` reconcilers are disabled below; the Deployment
# reconciler no-ops by itself because the outpost is embedded, which is why the
# kubernetes_json_patches that used to sit here never did anything.
#
# What the record is still FOR: it carries the catchall proxy provider, so the
# inline outpost knows which provider to serve, and it is the object authentik's
# UI shows as the embedded outpost.
# -----------------------------------------------------------------------------

resource "authentik_outpost" "embedded" {
  name               = "authentik Embedded Outpost"
  type               = "proxy"
  protocol_providers = [authentik_provider_proxy.catchall.id]
  service_connection = "99e227a7-4562-4888-9660-4c27da678c50"
  config = jsonencode({
    # info, not trace: the outpost sits on the hot path of every request to
    # every auth="required" ingress — trace logging is per-request overhead
    # with no operational value (request access lines are emitted at info).
    log_level        = "info"
    docker_labels    = null
    authentik_host   = "https://authentik.viktorbarzin.me/"
    docker_network   = null
    container_image  = null
    docker_map_ports = true
    refresh_interval = "minutes=5"
    # Inert since 2026-09-19: the Deployment reconciler no-ops on an embedded
    # outpost, so this asks for pods nobody creates. Left at 2 rather than 0 so
    # that if the outpost ever stops being embedded it comes back redundant
    # instead of absent. Forward-auth concurrency now comes from the three
    # goauthentik-server replicas that host the inline outpost.
    kubernetes_replicas           = 2
    kubernetes_namespace          = "authentik"
    authentik_host_browser        = ""
    object_naming_template        = "ak-outpost-%(name)s"
    authentik_host_insecure       = false
    kubernetes_service_type       = "ClusterIP"
    kubernetes_ingress_path_type  = null
    kubernetes_image_pull_secrets = []
    kubernetes_ingress_class_name = null
    # "service": authentik must stop writing this outpost's Service, because we
    # own its selector and point it at the inline outpost in the
    # goauthentik-server pods (bead code-osvg, cut over 2026-09-19). Honoured
    # because outpost_controller always dispatches through up_with_logs
    # (tasks.py), which skips any reconciler named here (kubernetes.py).
    #
    # Leaving it enabled would be actively harmful rather than merely
    # redundant: the reconciler updates the Service with a WHOLE-OBJECT MERGE
    # patch, and merging its 2-key reference selector over a 5-key live one
    # yields a 6-key selector matching ZERO pods, which never converges.
    # Measured with kubectl --dry-run=server on 2026-09-18.
    # "ingress" added 2026-09-19 alongside "service". Both callback Ingresses
    # serve authentik.viktorbarzin.me/outpost.goauthentik.io and Traefik takes
    # BOTH, because it runs with no ingressClass filter, so a middleware
    # attached to ours alone would fire only on the requests Traefik happened to
    # route there. Measured during the cutover: 5 callbacks went to the
    # controller's router and 1 to ours. Disabling the reconciler lets the
    # controller's copy be deleted for good, leaving one Ingress we own and can
    # attach middleware to.
    kubernetes_disabled_components   = ["service", "ingress"]
    kubernetes_ingress_annotations   = {}
    kubernetes_ingress_secret_name   = "authentik-outpost-tls"
    kubernetes_httproute_annotations = {}
    kubernetes_httproute_parent_refs = []
    # Deliberately empty, and kept rather than dropped so the server-side value
    # is reset to {} instead of left at whatever it last held. The deployment
    # patches that stood here (dshm volume, resources, a component=server label,
    # five Postgres env vars, and a readinessProbe added 2026-09-18) were inert
    # from the day authentik added the is_embedded guard to
    # DeploymentReconciler.noop, and the Deployment they targeted was deleted on
    # 2026-09-19 when forward-auth moved to the inline outpost.
    kubernetes_json_patches = {}
  })
}

# -----------------------------------------------------------------------------
# Default User Login stage — bound to default-authentication-flow.
# Adopted into Terraform 2026-05-01 to set session_duration=weeks=4 so users
# stay logged in across browser restarts. There is no Brand.session_duration
# in authentik 2026.2.x — UserLoginStage is the correct knob.
# -----------------------------------------------------------------------------

resource "authentik_stage_user_login" "default_login" {
  name             = "default-authentication-login"
  session_duration = "weeks=4"
  lifecycle {
    # Pin only session_duration; everything else stays UI-managed so the
    # plan doesn't churn unrelated knobs (e.g. remember_me_offset toggles).
    ignore_changes = [
      remember_me_offset,
      terminate_other_sessions,
      geoip_binding,
      network_binding,
    ]
  }
}

# -----------------------------------------------------------------------------
# Source (social-login) User Login stage — bound to default-source-authentication-flow.
# Adopted into Terraform 2026-06-20: its session_duration was the provider default
# "seconds=0", which falls back to AUTHENTIK_SESSIONS__UNAUTHENTICATED_AGE (hours=2).
# So Google/GitHub/Facebook logins expired every 2h while password and passkey
# logins (default-authentication-login) lasted weeks=4. After the 2026-06-18 passkey
# wipe forced fallback to Google login, this 2h cap became the "re-login multiple
# times daily" symptom. Pinning weeks=4 makes every login path consistent.
# See docs/architecture/authentication.md.
# -----------------------------------------------------------------------------
import {
  to = authentik_stage_user_login.default_source_login
  id = "4c6977d2-eaae-4033-b1db-21b48c6b47f0"
}

resource "authentik_stage_user_login" "default_source_login" {
  name             = "default-source-authentication-login"
  session_duration = "weeks=4"
  lifecycle {
    # Pin only session_duration; everything else stays UI-managed (same pattern
    # as authentik_stage_user_login.default_login above).
    ignore_changes = [
      remember_me_offset,
      terminate_other_sessions,
      geoip_binding,
      network_binding,
    ]
  }
}

# -----------------------------------------------------------------------------
# Default Identification stage — adopted 2026-06-10 to embed the password
# field on the identification screen (single-screen login: one round trip and
# one screen instead of two). Per authentik docs, when an Identification stage
# carries a password stage the Password stage must NOT be bound separately —
# the redundant order-20 binding on default-authentication-flow (pk
# 0fc677db-a23f-4ee7-8648-da342e14573b) was deleted via the API in the same
# change. Social-login users are unaffected: source buttons stay on the same
# screen and bypass the password field.
# -----------------------------------------------------------------------------

data "authentik_stage" "default_authentication_password" {
  name = "default-authentication-password"
}

resource "authentik_stage_identification" "default_identification" {
  name           = "default-authentication-identification"
  password_stage = data.authentik_stage.default_authentication_password.id
  # The "Sign up" link on the login page. Was null until 2026-09-02, so an
  # invitee with no account reached this page and had no way forward — the
  # invite flow was only reachable by someone already mid-Google redirect
  # (infra#51, stories 1 and 2). Pinned here rather than left UI-managed
  # because it is now load-bearing for signup.
  enrollment_flow = authentik_flow.signup_start.uuid
  lifecycle {
    # Pin only password_stage; everything else stays UI-managed (same pattern
    # as authentik_stage_user_login.default_login above).
    # NOTE: do NOT add webauthn_stage / enable_remember_me here — the pinned
    # authentik TF provider's authentik_stage_identification resource exposes no
    # such attributes (verified 2026-06-20: `tg plan` => "Unsupported attribute").
    # They exist on Authentik's IdentificationStage *model* but not in the
    # provider schema, so Terraform never manages or nulls them; they are purely
    # UI/app-managed and need no ignore_changes entry. Commit 4e882989 removed
    # them for exactly this reason — re-adding them breaks every apply.
    ignore_changes = [
      user_fields,
      case_insensitive_matching,
      show_matched_user,
      show_source_labels,
      sources,
      # enrollment_flow is NO LONGER ignored — it is set above, deliberately.
      # recovery_flow IS still ignored, on purpose: the "Forgot access?" link is
      # wired in a separate commit once the complete flow has been verified
      # live. Publishing the entry point in the same apply that builds the flow
      # is how a partial failure went live on 2026-09-02.
      recovery_flow,
      passwordless_flow,
      pretend_user_exists,
      captcha_stage,
    ]
  }
}
