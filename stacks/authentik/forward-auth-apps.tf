# Per-host forward-auth applications for hosts that a non-admin group may reach
# (ADR-0031, superseding ADR-0023).
#
# WHY. Every auth="required" host goes through the one Traefik forward-auth
# middleware. With nothing else configured, the inline outpost answers it from
# the domain-level catch-all ("Domain wide catch all", forward_domain), and that
# provider can only say yes or no once, at login, for the whole domain. Its one
# group binding is Home Server Admins (catchall-access-binding.tf), so before
# this file existed every non-admin grant written in an ingress's
# allowed_groups was refused. The full account is in ADR-0031.
#
# WHAT THIS FILE DOES. For each host in forward-auth-apps.json it creates a
# forward_single proxy provider with that host as external_host, an
# application, and one group binding per listed group plus Home Server Admins.
# The inline outpost matches an exact external_host before it falls back to the
# catch-all (src/outpost/proxy/mod.rs lookup_app in authentik 2026.8.3), so
# these hosts are answered by their own application and its bindings, and
# every other host keeps the catch-all. Each provider signs its own host-only
# cookie, so a session on one host opens nothing else.
#
# The login callback comes back on the host itself, at
# <host>/outpost.goauthentik.io/callback, so a host belongs in the JSON only if
# its "/" ingress goes through forward auth. f1 and tripit are not in it for
# that reason: forward auth there covers only /admin/login and /metrics, and
# their members sign in over their own OIDC apps instead.
#
# DECLARING ACCESS. A host appears in two places that must agree: its ingress
# `allowed_groups` (where readers of the app stack look) and the JSON (what is
# enforced). scripts/check-allowed-groups.py fails the stack before plan if they
# differ. Home Server Admins is implied in the JSON and bound on every host.
#
# ORDERING. An application with no bindings admits any signed-in user,
# including the silent `guest` identity. The outpost therefore depends_on every
# binding, so a provider is served only after its bindings exist, and on removal
# the outpost drops a provider before its bindings are destroyed.

locals {
  forward_auth_apps = jsondecode(file("${path.module}/forward-auth-apps.json"))

  # Groups this stack creates. Looked up by resource, because a data source
  # cannot read a group that the same apply is creating.
  forward_auth_tf_groups = {
    "Home Users"   = authentik_group.home_users.id
    "Chrome Users" = authentik_group.chrome_users.id
    "Proxy Users"  = authentik_group.proxy_users.id
  }

  forward_auth_group_ids = merge(
    { for name, g in data.authentik_group.forward_auth : name => g.id },
    local.forward_auth_tf_groups,
  )

  # host/group -> binding. Admins at order 0, listed groups after.
  forward_auth_bindings = merge([
    for host, groups in local.forward_auth_apps : merge(
      { "${host}/Home Server Admins" = { host = host, group = "Home Server Admins", order = 0 } },
      { for i, g in groups : "${host}/${g}" => { host = host, group = g, order = i + 1 } },
    )
  ]...)
}

data "authentik_group" "forward_auth" {
  for_each = setsubtract(
    toset(concat(["Home Server Admins"], flatten(values(local.forward_auth_apps)))),
    keys(local.forward_auth_tf_groups),
  )
  name          = each.value
  include_users = false
}

resource "authentik_provider_proxy" "forward_auth" {
  for_each = local.forward_auth_apps

  name                  = "Forward auth: ${each.key}"
  mode                  = "forward_single"
  external_host         = "https://${each.key}"
  authorization_flow    = data.authentik_flow.default_authorization_implicit_consent.id
  invalidation_flow     = data.authentik_flow.default_provider_invalidation.id
  access_token_validity = "weeks=4"

  lifecycle {
    # Authentik fills in the default scope mappings (which carry the
    # X-authentik-groups header) on create; the provider never sends them.
    ignore_changes = [property_mappings]
  }
}

resource "authentik_application" "forward_auth" {
  for_each = local.forward_auth_apps

  name               = "${trimsuffix(each.key, ".viktorbarzin.me")} (forward auth)"
  slug               = "fa-${trimsuffix(each.key, ".viktorbarzin.me")}"
  protocol_provider  = authentik_provider_proxy.forward_auth[each.key].id
  meta_launch_url    = "https://${each.key}"
  policy_engine_mode = "any"
}

resource "authentik_policy_binding" "forward_auth" {
  for_each = local.forward_auth_bindings

  target = authentik_application.forward_auth[each.value.host].uuid
  group  = local.forward_auth_group_ids[each.value.group]
  order  = each.value.order
}
