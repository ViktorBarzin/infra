# =============================================================================
# Public Guest user + auto-login flow + public proxy provider + dedicated
# outpost.
#
# Backs the `auth = "public"` tier of the ingress_factory module. Architecture:
#
#   * `guest` user (in `Public Guests` group, NOT `Allow Login Users`).
#   * `public-auto-login` flow: anonymous user enters → expression policy sets
#     `pending_user = guest` → user_login stage logs them in. No UI shown.
#   * `Provider for Public` proxy provider (forward_domain, cookie_domain
#     `viktorbarzin.me`) with `authentication_flow = public-auto-login`.
#   * Dedicated `Public Outpost` Deployment+Service (managed by Authentik's
#     K8s controller). Bound to the public provider only — there is no other
#     provider claiming `viktorbarzin.me` on this outpost, so every request
#     it sees runs the public flow regardless of host.
#   * `public-auth.viktorbarzin.me` ingress exposes the public outpost's
#     `/outpost.goauthentik.io/*` path so OAuth callbacks land on it (the
#     embedded outpost doesn't know about the public provider, so callbacks
#     can't go to authentik.viktorbarzin.me).
#
# Traffic flow for a stranger hitting an `auth = "public"` ingress:
#   1. Traefik's `authentik-forward-auth-public` middleware → public outpost.
#   2. No session cookie → 302 to `https://authentik.viktorbarzin.me/...`
#      with redirect_uri = `https://public-auth.viktorbarzin.me/.../callback`.
#   3. Authentik runs `public-auto-login` (no UI), issues session.
#   4. 302 → public-auth.viktorbarzin.me callback → public outpost validates
#      state and sets `authentik_proxy_<public-hash>` cookie on `viktorbarzin.me`.
#   5. 302 → original URL → Traefik retries forward_auth → public outpost
#      validates cookie → 200 with `X-authentik-username: guest`.
#
# A user already logged into anything else on viktorbarzin.me (the catchall)
# still gets recognised here — Authentik prefers an existing session and the
# public provider's authorization_flow auto-approves anyone, so their real
# username shows up in `X-authentik-username`. Strangers get `guest`.
# =============================================================================

resource "authentik_user" "guest" {
  username  = "guest"
  name      = "Guest"
  path      = "users/system"
  is_active = true
  type      = "internal"
  # No password set: the user_login stage in `public_auto_login` logs the
  # request in via pending_user pre-set by an expression policy. There is no
  # UI path for `guest` to authenticate via password — the user is also kept
  # out of `Allow Login Users`, so even a leaked password cannot be used to
  # complete the standard login flow.
  lifecycle {
    ignore_changes = [attributes, email]
  }
}

resource "authentik_group" "public_guests" {
  name  = "Public Guests"
  users = [authentik_user.guest.id]
  # NOT a child of "Allow Login Users" — keeps a hypothetical leaked password
  # from promoting `guest` to a real user via the standard login flow.
}

# Pre-stage policy: sets pending_user = guest before user_login stage runs.
# Mutates `request.context["flow_plan"].context["pending_user"]` — the
# canonical pattern (the user_login stage reads pending_user from
# `flow_plan.context`). Direct `request.context["pending_user"]` mutations
# don't propagate, since policy request.context is not the same dict as
# flow_plan.context.
resource "authentik_policy_expression" "set_guest_user" {
  name              = "set-public-guest-user"
  execution_logging = true
  expression = trimspace(<<-EOT
    request.context["flow_plan"].context["pending_user"] = ak_user_by(username="guest")
    return True
  EOT
  )
}

# Dedicated user_login stage for the public flow. 4-week session matches the
# default authentication stage; means a stranger only goes through the auto-
# bind once per ~month per device.
resource "authentik_stage_user_login" "public_guest_login" {
  name             = "public-guest-login"
  session_duration = "weeks=4"
}

# `authentication = "none"` lets anonymous requests run the flow.
# `designation = "authentication"` because the flow's outcome is "request is
# now authenticated as guest"; the public proxy provider's authorization_flow
# then runs implicit consent.
resource "authentik_flow" "public_auto_login" {
  name           = "Public Auto Login"
  slug           = "public-auto-login"
  title          = "Public Guest Login"
  designation    = "authentication"
  authentication = "none"
}

resource "authentik_flow_stage_binding" "public_login" {
  target = authentik_flow.public_auto_login.uuid
  stage  = authentik_stage_user_login.public_guest_login.id
  order  = 10
  # Re-evaluate at stage runtime: at plan time, flow_plan may not yet be in
  # request.context, so the expression policy's mutation would no-op. With
  # evaluate_on_plan=false + re_evaluate_policies=true, the policy fires
  # right before the stage runs, when flow_plan is fully populated.
  evaluate_on_plan       = false
  re_evaluate_policies   = true
}

resource "authentik_policy_binding" "set_guest_before_login" {
  target = authentik_flow_stage_binding.public_login.id
  policy = authentik_policy_expression.set_guest_user.id
  order  = 0
}

# -----------------------------------------------------------------------------
# Public proxy provider — forward_domain so it claims any host on
# viktorbarzin.me. Used only on the dedicated `public` outpost (where it is
# the sole bound provider), so there's no dispatch ambiguity with the
# catchall (which lives on the embedded outpost).
# -----------------------------------------------------------------------------
resource "authentik_provider_proxy" "public" {
  name          = "Provider for Public"
  mode          = "forward_domain"
  external_host = "https://public-auth.viktorbarzin.me"
  cookie_domain = "viktorbarzin.me"

  # When a request hits with NO Authentik session, this flow runs first and
  # auto-binds the request to the `guest` user (no UI prompt).
  authentication_flow = authentik_flow.public_auto_login.uuid
  # Once authenticated (or already authenticated), implicit-consent auto-approves.
  authorization_flow = data.authentik_flow.default_authorization_implicit_consent.id
  invalidation_flow  = data.authentik_flow.default_provider_invalidation.id

  access_token_validity = "weeks=4"

  lifecycle {
    ignore_changes = [property_mappings, jwt_federation_sources, skip_path_regex, internal_host, basic_auth_enabled, basic_auth_password_attribute, basic_auth_username_attribute, intercept_header_auth]
  }
}

resource "authentik_application" "public" {
  name              = "Public"
  slug              = "public"
  protocol_provider = authentik_provider_proxy.public.id
  # No bound policies. policy_engine_mode = "any" + zero bindings = everyone
  # passes (the auto-login flow has already established `guest` as the user).
  policy_engine_mode = "any"

  lifecycle {
    ignore_changes = [meta_description, meta_launch_url, meta_icon, group, backchannel_providers, open_in_new_tab]
  }
}

# Dedicated outpost so the public provider can claim viktorbarzin.me without
# colliding with the catchall (which already claims viktorbarzin.me on the
# embedded outpost). Authentik's K8s controller deploys this as
# `ak-outpost-public` (Deployment + Service in the `authentik` namespace).
resource "authentik_outpost" "public" {
  name               = "public"
  type               = "proxy"
  protocol_providers = [authentik_provider_proxy.public.id]
  service_connection = "99e227a7-4562-4888-9660-4c27da678c50"
  config = jsonencode({
    log_level                        = "info"
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
          path  = "/spec/template/spec/containers/0/resources"
          value = { limits = { memory = "256Mi" }, requests = { cpu = "10m", memory = "64Mi" } }
        },
      ]
    }
  })
}

# Ingress for `public-auth.viktorbarzin.me` — exposes the public outpost's
# /outpost.goauthentik.io/* path so OAuth callbacks land on it. The
# `Provider for Public` external_host points here, so all redirect_uris in
# the OAuth flow resolve to this hostname.
module "ingress_public_outpost" {
  source           = "../../modules/kubernetes/ingress_factory"
  namespace        = "authentik"
  name             = "public-outpost"
  host             = "public-auth"
  service_name     = "ak-outpost-public"
  port             = 9000
  ingress_path     = ["/outpost.goauthentik.io"]
  tls_secret_name  = var.tls_secret_name
  dns_type         = "proxied"
  anti_ai_scraping = false
  exclude_crowdsec = true
  homepage_enabled = false
  depends_on       = [authentik_outpost.public]
}
