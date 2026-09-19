# Forward-auth authorization — default-deny host->groups table (ADR-0023, infra#84).
#
# All ~100 auth="required" hosts share ONE catch-all provider + this ONE expression
# policy (Authentik domain-level forward-auth cannot bind per-app policies). The
# table below is GENERATED from the live ingress inventory: ingress_factory stamps
# `authentik.viktorbarzin.me/allowed-groups` on every forward-auth ingress, and the
# kubernetes_resources data source reads them at apply time. "Who logs in where" is
# therefore declared on the ingress; this file only materialises + enforces it.
#
# CORRECTION 2026-09-19: the table above is NOT an enforcement mechanism and
# never was. In domain-level forward auth the policy engine is not in the
# per-request path at all. The outpost answers from the session cookie and never
# calls Python. The single evaluation happens once, at the OAuth authorize step,
# against authentik.viktorbarzin.me, where `host` is empty. So the old body's
# first line, `if not host: return True`, granted every authenticated user every
# one of the 87 forward-auth hosts, and the rest of the table was unreachable.
# Authentik's maintainer states the consequence in goauthentik/authentik
# discussion #13823: "authorization will happen once when the user access
# anything.my.com and then the user will have access to *.my.com without further
# re-authorization." The docs agree: domain-level forward auth "cannot restrict
# individual applications to different users with separate application-level
# policies".
#
# This went unnoticed for eight weeks because the July verification used the
# policy-test API (POST /api/v3/policies/all/{uuid}/test/), which SUPPLIES a host
# in the test context. It exercised the expression and never the enforcement
# path. A policy unit test cannot prove the outpost passes a host. Measured
# instead on 2026-09-19: a throwaway account in ZERO groups signed in and was
# served the full learn.viktorbarzin.me topic list and the Grafana dashboards.
#
# WHAT ENFORCES NOW. The expression returns False, so the catch-all application
# is gated solely by its "Home Server Admins" group binding
# (catchall-access-binding.tf). That is correct for 85 of the 87 hosts.
#
# WHAT IS STILL OWED. Six hosts are meant to be reachable by non-admins: chrome,
# chrome-fleet, k8s, pages, proxy, t3. Those users are denied until the hosts
# move to per-application forward_single providers with native group bindings,
# which is the next change. Affected today: three accounts, one host each. The
# generator below is kept because that change consumes the same annotations to
# decide which hosts need a per-app provider.
#
# The declaration has not moved: `allowed_groups` on the ingress is still where
# access is stated. Only the thing that reads it changes. Access is GROUP
# MEMBERSHIP ONLY: the former chrome per-identity list is now the `Chrome Users`
# group and the proxy_only attribute path is gone (chrome_users.tf, and the
# per-app rows in the owning stacks). The binding attaching this policy to the
# "Domain wide catch all" application stays UI-managed.
import {
  to = authentik_policy_expression.admin_services_restriction
  id = "07a11b85-8f37-4844-aebb-ac9c112ec87c"
}

# Live ingress inventory. NOTE: kubernetes_resources with NO namespace returns an
# EMPTY list for namespaced kinds in this provider version (verified 2026-07-26 —
# cluster-wide list yields 0). So enumerate namespaces and list per-namespace, then
# flatten. Prior art for kubernetes_resources: stacks/nextcloud/main.tf.
data "kubernetes_all_namespaces" "all" {}

data "kubernetes_resources" "ingresses" {
  for_each    = toset(data.kubernetes_all_namespaces.all.namespaces)
  api_version = "networking.k8s.io/v1"
  kind        = "Ingress"
  namespace   = each.value
}

locals {
  # The forward-auth middleware every auth="required" ingress carries. We key off
  # this (not a hardcoded host list) so the table auto-covers every forward-auth
  # app — including ones whose stack hasn't been re-applied since Phase 1 (they
  # default to Home Server Admins below, staying admin-reachable + non-admin-denied).
  _forward_auth_mw = "traefik-authentik-forward-auth@kubernetescrd"

  _all_ingresses = flatten([for ns, res in data.kubernetes_resources.ingresses : res.objects])

  _fa_ingresses = [
    for o in local._all_ingresses : o
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
    # This policy no longer grants anything. See the file header: in
    # domain-level forward auth the policy engine is not in the per-request
    # path, so a host-keyed table here can never gate a host. The previous
    # body opened with `if not host: return True`, and because host is ALWAYS
    # empty on the only evaluation that happens, that line granted every
    # authenticated user every one of the 87 forward-auth hosts.
    #
    # The catch-all application is policy_engine_mode="any" with two bindings,
    # so returning False here leaves the "Home Server Admins" group binding
    # (catchall-access-binding.tf) as the sole gate, which is what makes the
    # catch-all admin-only.
    #
    # The binding that attaches this policy to the application is still
    # UI-managed. Removing it is tidier than leaving an inert policy bound,
    # and needs an import-then-destroy pair; tracked as follow-up, not done
    # here because this change had to be small.
    return False
  EOT
  )
}
