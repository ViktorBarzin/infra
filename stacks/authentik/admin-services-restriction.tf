# Forward-auth authorization — default-deny host->groups table (ADR-0023, infra#84).
#
# All ~100 auth="required" hosts share ONE catch-all provider + this ONE expression
# policy (Authentik domain-level forward-auth cannot bind per-app policies). The
# table below is GENERATED from the live ingress inventory: ingress_factory stamps
# `authentik.viktorbarzin.me/allowed-groups` on every forward-auth ingress, and the
# kubernetes_resources data source reads them at apply time. "Who logs in where" is
# therefore declared on the ingress; this file only materialises + enforces it.
#
# Semantics (top to bottom):
#   1. empty host  -> grant (the OAuth authorize step of proxy OIDC clients has no
#      host; the per-request check, host set, does the real gating).
#   2. BREAK-GLASS -> admins (authentik Admins / Home Server Admins) ALWAYS pass,
#      evaluated BEFORE the table so no generator/table state can lock out the owner
#      (Viktor's explicit invariant, 2026-07-26). Non-admins are unaffected.
#   3. table lookup -> grant iff the user is in one of the host's allowed groups;
#      unlisted host or no-matching-group -> DENY (default-deny).
#
# Access is GROUP MEMBERSHIP ONLY: the former chrome per-identity list is now the
# `Chrome Users` group and the proxy_only attribute path is gone (chrome_users.tf,
# and the per-app rows in the owning stacks). The binding to the "Domain wide catch
# all" application stays UI-managed; only the expression is adopted here.
import {
  to = authentik_policy_expression.admin_services_restriction
  id = "07a11b85-8f37-4844-aebb-ac9c112ec87c"
}

# Live ingress inventory (cluster-wide). Prior art: stacks/nextcloud/main.tf.
data "kubernetes_resources" "ingresses" {
  api_version = "networking.k8s.io/v1"
  kind        = "Ingress"
}

locals {
  # The forward-auth middleware every auth="required" ingress carries. We key off
  # this (not a hardcoded host list) so the table auto-covers every forward-auth
  # app — including ones whose stack hasn't been re-applied since Phase 1 (they
  # default to Home Server Admins below, staying admin-reachable + non-admin-denied).
  _forward_auth_mw = "traefik-authentik-forward-auth@kubernetescrd"

  _fa_ingresses = [
    for o in data.kubernetes_resources.ingresses.objects : o
    if strcontains(
      try(o.metadata.annotations["traefik.ingress.kubernetes.io/router.middlewares"], ""),
      local._forward_auth_mw
    )
  ]

  # (host, groups) pairs. Missing annotation -> the safe default. trimspace drops
  # any stray whitespace from the comma-join.
  _fa_pairs = flatten([
    for o in local._fa_ingresses : [
      for r in try(o.spec.rules, []) : {
        host = try(r.host, "")
        groups = [
          for g in split(",", try(o.metadata.annotations["authentik.viktorbarzin.me/allowed-groups"], "Home Server Admins")) :
          trimspace(g) if trimspace(g) != ""
        ]
      } if try(r.host, "") != ""
    ]
  ])

  _fa_hosts = distinct([for p in local._fa_pairs : p.host])

  # host -> unioned allowed groups (union handles path carve-out ingresses that
  # share a host). This is the generated table rendered into the policy below.
  host_groups = {
    for h in local._fa_hosts :
    h => distinct(flatten([for p in local._fa_pairs : p.groups if p.host == h]))
  }
}

resource "authentik_policy_expression" "admin_services_restriction" {
  name = "admin-services-restriction"
  expression = trimspace(<<-EOT
    # GENERATED default-deny forward-auth authorization (ADR-0023, infra#84).
    # HOST_GROUPS is rendered from live ingress allowed-groups annotations at
    # `terragrunt apply` time — edit access on the ingress, never here.
    HOST_GROUPS = ${jsonencode(local.host_groups)}

    host = request.context.get("host", "")

    # (1) OAuth authorize step of proxy OIDC clients has no host -> grant; the
    # per-request check (host populated) does the real gating.
    if not host:
        return True

    # (2) BREAK-GLASS: admins ALWAYS reach every forward-auth host. Evaluated
    # BEFORE the table so no generator/table state can ever lock out the owner.
    if ak_is_group_member(request.user, name="authentik Admins") or ak_is_group_member(request.user, name="Home Server Admins"):
        return True

    # (3) Default-deny table: grant iff the user is in one of the host's groups.
    allowed = HOST_GROUPS.get(host)
    if not allowed:
        return False
    return any(ak_is_group_member(request.user, name=g) for g in allowed)
  EOT
  )
}
