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
#   - kubernetes_json_patches.deployment carries:
#       * dshm 2Gi tmpfs (covers the 2026-04-18 ENOSPC class of issues)
#       * resources requests/limits
#       * `app.kubernetes.io/component=server` pod label so the K8s service
#         selector lights up endpoints (works around goauthentik 2026.2.2
#         service.py:52 selector mismatch on standalone embedded outposts).
#       * AUTHENTIK_POSTGRESQL__{HOST,PORT,USER,PASSWORD,NAME} envFrom the
#         shared `goauthentik` Secret so the postgres session backend has
#         credentials to connect to the dbaas cluster.
#   - kubernetes_json_patches.service replaces the controller-set selector
#     (which incorrectly targets `app.kubernetes.io/name=authentik`, i.e.
#     the goauthentik-server pods) with the outpost's own labels.
# -----------------------------------------------------------------------------

resource "authentik_outpost" "embedded" {
  name               = "authentik Embedded Outpost"
  type               = "proxy"
  protocol_providers = [authentik_provider_proxy.catchall.id]
  service_connection = "99e227a7-4562-4888-9660-4c27da678c50"
  config = jsonencode({
    log_level                        = "trace"
    docker_labels                    = null
    authentik_host                   = "https://authentik.viktorbarzin.me/"
    docker_network                   = null
    container_image                  = null
    docker_map_ports                 = true
    refresh_interval                 = "minutes=5"
    kubernetes_replicas              = 1
    kubernetes_namespace             = "authentik"
    authentik_host_browser           = ""
    object_naming_template           = "ak-outpost-%(name)s"
    authentik_host_insecure          = false
    kubernetes_service_type          = "ClusterIP"
    kubernetes_ingress_path_type     = null
    kubernetes_image_pull_secrets    = []
    kubernetes_ingress_class_name    = null
    kubernetes_disabled_components   = []
    kubernetes_ingress_annotations   = {}
    kubernetes_ingress_secret_name   = "authentik-outpost-tls"
    kubernetes_httproute_annotations = {}
    kubernetes_httproute_parent_refs = []
    kubernetes_json_patches = {
      deployment = [
        {
          op    = "add"
          path  = "/spec/template/spec/volumes"
          value = [{ name = "dshm", emptyDir = { medium = "Memory", sizeLimit = "2Gi" } }]
        },
        {
          op    = "add"
          path  = "/spec/template/spec/containers/0/volumeMounts"
          value = [{ name = "dshm", mountPath = "/dev/shm" }]
        },
        {
          op    = "add"
          path  = "/spec/template/spec/containers/0/resources"
          value = { limits = { memory = "2560Mi" }, requests = { cpu = "100m", memory = "128Mi" } }
        },
        {
          op    = "add"
          path  = "/spec/template/metadata/labels/app.kubernetes.io~1component"
          value = "server"
        },
        {
          op    = "add"
          path  = "/spec/template/spec/containers/0/env/-"
          value = { name = "AUTHENTIK_POSTGRESQL__HOST", valueFrom = { secretKeyRef = { name = "goauthentik", key = "AUTHENTIK_POSTGRESQL__HOST" } } }
        },
        {
          op    = "add"
          path  = "/spec/template/spec/containers/0/env/-"
          value = { name = "AUTHENTIK_POSTGRESQL__PORT", valueFrom = { secretKeyRef = { name = "goauthentik", key = "AUTHENTIK_POSTGRESQL__PORT" } } }
        },
        {
          op    = "add"
          path  = "/spec/template/spec/containers/0/env/-"
          value = { name = "AUTHENTIK_POSTGRESQL__USER", valueFrom = { secretKeyRef = { name = "goauthentik", key = "AUTHENTIK_POSTGRESQL__USER" } } }
        },
        {
          op    = "add"
          path  = "/spec/template/spec/containers/0/env/-"
          value = { name = "AUTHENTIK_POSTGRESQL__PASSWORD", valueFrom = { secretKeyRef = { name = "goauthentik", key = "AUTHENTIK_POSTGRESQL__PASSWORD" } } }
        },
        {
          op    = "add"
          path  = "/spec/template/spec/containers/0/env/-"
          value = { name = "AUTHENTIK_POSTGRESQL__NAME", valueFrom = { secretKeyRef = { name = "goauthentik", key = "AUTHENTIK_POSTGRESQL__NAME" } } }
        },
      ]
      service = [
        {
          op   = "replace"
          path = "/spec/selector"
          value = {
            "app.kubernetes.io/managed-by" = "goauthentik.io"
            "app.kubernetes.io/name"       = "authentik-outpost-proxy"
            "goauthentik.io/outpost-name"  = "authentik-embedded-outpost"
            "goauthentik.io/outpost-type"  = "proxy"
            "goauthentik.io/outpost-uuid"  = "0eecac0797c7443c892505f2f4fe3e47"
          }
        },
      ]
    }
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
