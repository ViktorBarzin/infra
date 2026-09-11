# =============================================================================
# RAC (Remote Access Control) provider + outpost — SSH, RDP and VNC through
# authentik, prepared for use.
#
# Step 7 of docs/plans/2026-09-01-service-identity-and-request-attribution-design.md.
# RAC gives shell and desktop access a named authentik principal and a recorded
# session, which is the same attribution goal as the LDAP half; it is free and
# open source (see the licence note below).
#
# PREPARED, NOT ENABLED. `local.rac_outpost_replicas = 0` and no endpoints are
# declared, so the application resolves to an empty endpoint list and nothing can
# be connected to. No existing service changes behaviour.
#
# No ingress, and none is possible. The RAC Kubernetes controller sets
# `deployment_ports = []` and DELETES the Service reconciler, so the outpost gets
# a Deployment and nothing else; it dials the authentik server outbound over a
# websocket. The browser side is served by the authentik server itself on paths
# the existing `authentik.viktorbarzin.me` ingress already covers:
#   /application/rac/<app-slug>/<endpoint-uuid>/   launch
#   /if/rac/<token>/                               the session interface
#   /ws/rac/<token>/                               browser <-> server websocket
#   /ws/outpost_rac/<channel>/                     outpost  <-> server websocket
# That ingress is auth = "none" because authentik cannot gate its own UI, so the
# `auth` tier conventions and `ingress_factory` have nothing to add here — access
# control is the application policy binding below, not a Traefik middleware.
# Verified against the live 2026.8.0 server source, 2026-09-01.
#
# LICENCE, settled from our own instance rather than the docs (2026-09-01):
# no licence is required. /api/v3/enterprise/license/summary/ reports
# `status: unlicensed`, and RAC lives at the OSS app label
# `authentik.providers.rac` (model `authentik_providers_rac.racprovider`) with a
# plain ModelViewSet. Every licence-gated provider sits under
# `authentik.enterprise.providers.*` and carries `EnterpriseRequiredMixin`, which
# appears nowhere in the RAC or LDAP packages.
#
# SESSION LENGTH is worth measuring at enable time. A RAC session is a browser
# websocket through the `websecure` entrypoint, whose respondingTimeouts are
# readTimeout=3600s, idleTimeout=600s, writeTimeout=0s. Those are total-duration
# caps rather than per-read idle timeouts, so how long a session survives is an
# empirical question, not one this comment can answer.
# =============================================================================

locals {
  # 0 = prepared and inert. Enabling means this, an endpoint (see the blocked
  # note at the bottom of this file), and a member in the group below.
  rac_outpost_replicas = 0
}

# -----------------------------------------------------------------------------
# Who may open a remote session. Same reasoning as postgres-ldap.tf: an
# application with no policy bindings is reachable by any authenticated user,
# because `core_default_app_access` defaults to True and this instance leaves it
# there. The group is created EMPTY.
# -----------------------------------------------------------------------------

resource "authentik_group" "rac_users" {
  name = "RAC Users"
  # Deliberately no members and no parent. A member here can open every endpoint
  # bound to the provider, so treat adding one as granting shell access.
  lifecycle {
    ignore_changes = [users]
  }
}

resource "authentik_provider_rac" "remote_access" {
  name = "Provider for Remote Access"
  # Implicit consent, matching every other first-party provider in this stack.
  authorization_flow = data.authentik_flow.default_authorization_implicit_consent.id
  # authentication_flow deliberately unset: the user is already signed in to
  # authentik when they launch an endpoint, so the brand's default applies.

  # A working day. Long enough not to interrupt a session, short enough that a
  # forgotten tab does not hold a connection token indefinitely.
  connection_expiry = "hours=8"

  # No provider-level settings. Per-endpoint settings carry the connection
  # parameters, and those are the ones that would hold credentials.
  settings = jsonencode({})
}

resource "authentik_application" "rac" {
  name = "Remote Access"
  slug = "remote-access"
  # protocol_provider, not backchannel: unlike LDAP, a RAC application is meant
  # to be launched from the authentik app grid.
  protocol_provider = authentik_provider_rac.remote_access.id

  lifecycle {
    ignore_changes = [meta_description, meta_launch_url, meta_icon, group, backchannel_providers, policy_engine_mode, open_in_new_tab]
  }
}

resource "authentik_policy_binding" "rac_access" {
  target = authentik_application.rac.uuid
  group  = authentik_group.rac_users.id
  order  = 0
}

# -----------------------------------------------------------------------------
# The outpost. Same config key set as the other two outposts so the three stay
# diff-able; the Kubernetes service and ingress keys are inert for a RAC outpost
# (no Service is created at all) and are kept only for that comparability.
# -----------------------------------------------------------------------------

resource "authentik_outpost" "rac" {
  name               = "rac"
  type               = "rac"
  protocol_providers = [authentik_provider_rac.remote_access.id]
  service_connection = "99e227a7-4562-4888-9660-4c27da678c50" # Local Kubernetes Cluster
  config = jsonencode({
    log_level        = "info"
    docker_labels    = null
    authentik_host   = "https://authentik.viktorbarzin.me/"
    docker_network   = null
    container_image  = null
    docker_map_ports = true
    refresh_interval = "minutes=5"
    # 0 while prepared: the Deployment exists, nothing runs. See
    # local.rac_outpost_replicas above.
    kubernetes_replicas              = local.rac_outpost_replicas
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
          # The RAC outpost bundles guacd, which allocates per active connection.
          # 512Mi is a starting ceiling for a single-session homelab, not a
          # measured one — re-measure before anyone relies on it.
          value = { limits = { memory = "512Mi" }, requests = { cpu = "10m", memory = "128Mi" } }
        },
      ]
    }
  })
}

# -----------------------------------------------------------------------------
# Endpoints are NOT declared here, and cannot be with the pinned provider.
#
# The authentik 2026.8.0 API requires `auth_mode` on endpoint creation
# (`EndpointRequest.required = [auth_mode, host, name, protocol, provider]`;
# the model field carries no default), and goauthentik/authentik 2024.12.1 —
# the version this stack pins in providers.tf — has no `auth_mode` attribute on
# `authentik_rac_endpoint`. A POST from that provider would be rejected 400.
#
# So an endpoint means one of: bump the authentik terraform provider (a
# stack-wide change that touches the six existing providers, worth its own
# review), or create endpoints in the UI and adopt them later. Either way it is
# a separate change, not a silent addition to this one. Shape for whoever picks
# it up:
#
#   resource "authentik_rac_endpoint" "devvm_ssh" {
#     name              = "devvm SSH"
#     protocol          = "ssh"                      # ssh | rdp | vnc
#     host              = "10.0.10.10:22"
#     protocol_provider = authentik_provider_rac.remote_access.id
#     # auth_mode       = "prompt"                   # prompt | static — needs a newer provider
#   }
# -----------------------------------------------------------------------------
