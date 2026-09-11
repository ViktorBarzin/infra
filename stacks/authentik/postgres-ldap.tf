# =============================================================================
# LDAP provider + outpost, prepared for Postgres `ldap` authentication.
#
# Step 7 of docs/plans/2026-09-01-service-identity-and-request-attribution-design.md:
# extend identity to the protocols Authentik can reach natively. Postgres cannot
# sit behind the proxy provider (that provider speaks HTTP only), so it gets an
# LDAP outpost and uses PostgreSQL's own `ldap` auth method against it.
#
# PREPARED, NOT ENABLED. `local.ldap_outpost_replicas = 0`, so Authentik's
# Kubernetes controller renders the Deployment and Service and runs no pod:
# nothing listens on 389/636 and no existing service changes behaviour. The
# Postgres half — pg_hba lines and PG roles — is a tier-0 database change and is
# deliberately NOT in this stack. What it needs is written down in
# docs/runbooks/authentik-ldap-rac-outposts.md.
#
# No ingress. The LDAP outpost's Kubernetes controller declares
# `DeploymentPort(389, "ldap", "tcp", 3389)` / `(636, "ldaps", ..., 6636)` /
# `(9300, "http-metrics", ...)` and adds no Ingress reconciler (only the proxy
# controller does that), so the outpost is reachable in-cluster as
# `ak-outpost-postgres-ldap.authentik.svc.cluster.local:389` and nowhere else.
# LDAP is not HTTP, so `ingress_factory` has nothing to express here and the
# `auth` tier conventions do not apply — there is no Traefik router to gate.
# Verified against the live 2026.8.0 server source, 2026-09-01.
#
# Bind DN shape, for the Postgres side:
#   cn=<username>,ou=users,dc=ldap,dc=viktorbarzin,dc=me
#
# Why a dedicated bind flow rather than `default-authentication-flow`: that flow
# carries `default-authentication-mfa-validation` at order 30, whose
# `device_classes` include `webauthn` and whose `not_configured_action` is
# `configure`. An LDAP bind has no browser, so a passkey challenge cannot be
# answered and a device-setup diversion cannot be completed — every bind by a
# passkey-only or device-less user would fail. The flow below is the same
# identification + login pair with no MFA stage. Measured on the live instance
# 2026-09-01.
# =============================================================================

locals {
  # 0 = prepared and inert. Flipping this to 1 is the whole Authentik-side
  # enablement step; the Postgres side is separate and needs its own review.
  ldap_outpost_replicas = 0
}

data "authentik_flow" "default_authentication" {
  slug = "default-authentication-flow"
}

# -----------------------------------------------------------------------------
# Bind flow. Identification carries the password stage (the single-screen
# pattern this stack already uses for the login UI), so there is deliberately NO
# separate password stage binding — authentik rejects that combination.
# -----------------------------------------------------------------------------

resource "authentik_flow" "ldap_bind" {
  name        = "LDAP Bind"
  slug        = "ldap-bind"
  title       = "LDAP Bind"
  designation = "authentication"
  # `none`: the caller is an unauthenticated LDAP bind, not a browser session.
  authentication = "none"
}

resource "authentik_stage_identification" "ldap_bind" {
  name = "ldap-bind-identification"
  # Username or email; no source buttons, no enrolment or recovery links — none
  # of those can be rendered to an LDAP client.
  user_fields = ["username", "email"]
  # Reuse the existing password stage rather than adding a second one to manage.
  password_stage = data.authentik_stage.default_authentication_password.id
}

resource "authentik_stage_user_login" "ldap_bind" {
  name = "ldap-bind-login"
  # Short on purpose: with `bind_mode = "direct"` the outpost runs this flow on
  # every bind and only needs the session for the access check that immediately
  # follows, so a long duration would just accumulate AuthenticatedSession rows
  # in the shared Postgres. Re-check the value against real bind volume once the
  # outpost is running.
  session_duration = "minutes=5"
}

resource "authentik_flow_stage_binding" "ldap_bind_identification" {
  target = authentik_flow.ldap_bind.uuid
  stage  = authentik_stage_identification.ldap_bind.id
  order  = 10
}

resource "authentik_flow_stage_binding" "ldap_bind_login" {
  target = authentik_flow.ldap_bind.uuid
  stage  = authentik_stage_user_login.ldap_bind.id
  order  = 100
}

# -----------------------------------------------------------------------------
# Who may bind. An application with no policy bindings is reachable by ANY
# authenticated user — the `core_default_app_access` flag defaults to True and
# this instance leaves it at the default (live `flags` map is empty, checked
# 2026-09-01), which is the same default-deny gap app-access-bindings.tf closed
# for the OIDC apps. So the binding below is required, not decorative.
#
# The group is created EMPTY: nobody can bind until a person is added to it,
# which is the second half of enabling this (the first being the replica count).
# -----------------------------------------------------------------------------

resource "authentik_group" "postgres_ldap_users" {
  name = "Postgres LDAP Users"
  # Deliberately no members and no parent. Adding a member grants that person
  # the ability to bind to Postgres as themselves; see the runbook.
  lifecycle {
    ignore_changes = [users]
  }
}

resource "authentik_provider_ldap" "postgres" {
  name    = "Provider for Postgres LDAP"
  base_dn = "dc=ldap,dc=viktorbarzin,dc=me"
  # bind_flow -> the API's authorization_flow, unbind_flow -> invalidation_flow
  # (the server's LDAPOutpostConfigSerializer reads bind_flow_slug from
  # authorization_flow.slug). Verified on 2026.8.0, 2026-09-01.
  bind_flow   = authentik_flow.ldap_bind.uuid
  unbind_flow = data.authentik_flow.default_provider_invalidation.id

  # `direct`: every bind and search hits the authentik API, so every bind
  # produces an authentik login event. `cached` would answer some binds from the
  # outpost's own user cache and lose exactly the attribution this design is for.
  bind_mode   = "direct"
  search_mode = "direct"

  # Appending `;<TOTP code>` to the password is accepted. Keeping authentik's own
  # default. Caveat worth knowing before adding anyone to the group above: a
  # password that itself contains a semicolon can be misparsed and rejected.
  mfa_support = true

  # authentik's documented defaults, set explicitly so an omission never reads as
  # a deliberate 0 (the provider sends these unconditionally).
  uid_start_number = 2000
  gid_start_number = 4000

  # certificate / tls_server_name deliberately unset — see the runbook for the
  # LDAPS-versus-plaintext decision, which belongs with the Postgres change.
}

# The LDAP provider is attached as a BACKCHANNEL provider: it has no launch URL,
# so this keeps the application off the user-facing app grid while still giving
# the outpost an application to resolve. The outpost config endpoint only returns
# providers that have an application or a backchannel application, so the
# application is required — an LDAP provider on its own is invisible to the
# outpost.
resource "authentik_application" "postgres_ldap" {
  name                  = "Postgres LDAP"
  slug                  = "postgres-ldap"
  backchannel_providers = [authentik_provider_ldap.postgres.id]

  lifecycle {
    ignore_changes = [meta_description, meta_launch_url, meta_icon, group, protocol_provider, policy_engine_mode, open_in_new_tab]
  }
}

resource "authentik_policy_binding" "postgres_ldap_access" {
  target = authentik_application.postgres_ldap.uuid
  group  = authentik_group.postgres_ldap_users.id
  order  = 0
}

# -----------------------------------------------------------------------------
# The outpost. Same config key set as the embedded and public outposts, so the
# stored config round-trips byte-for-byte (the server preserves exactly the keys
# it is given — verified by diffing the live `public` outpost config against this
# shape, 2026-09-01) and only `type` and the replica count differ.
#
# `kubernetes_service_type` and the ingress keys are inert for an LDAP outpost's
# Service but are kept so the three outposts stay diff-able against each other.
# -----------------------------------------------------------------------------

resource "authentik_outpost" "postgres_ldap" {
  name               = "postgres-ldap"
  type               = "ldap"
  protocol_providers = [authentik_provider_ldap.postgres.id]
  service_connection = "99e227a7-4562-4888-9660-4c27da678c50" # Local Kubernetes Cluster
  config = jsonencode({
    log_level        = "info"
    docker_labels    = null
    authentik_host   = "https://authentik.viktorbarzin.me/"
    docker_network   = null
    container_image  = null
    docker_map_ports = true
    refresh_interval = "minutes=5"
    # 0 while prepared: the Deployment and Service exist, nothing runs, nothing
    # listens. See local.ldap_outpost_replicas above.
    kubernetes_replicas              = local.ldap_outpost_replicas
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
          op   = "add"
          path = "/spec/template/spec/containers/0/resources"
          # Same envelope as the public proxy outpost, a known-good value in this
          # namespace. `search_mode = direct` keeps no user cache, so the working
          # set should sit well under the ceiling; measure once it runs.
          value = { limits = { memory = "256Mi" }, requests = { cpu = "10m", memory = "64Mi" } }
        },
      ]
    }
  })
}
