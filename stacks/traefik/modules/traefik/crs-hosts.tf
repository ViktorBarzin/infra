# Which hosts the bouncer sends to the OWASP core-rule-set AppSec listener
# (appsecCrsHosts on the crowdsec Middleware). Viktor's scope, 2026-10-02:
# public hosts with NO Authentik in front of them, where an app's own login is
# all that stands between it and anyone on the internet. Authentik-gated hosts
# keep virtual patching only: anonymous traffic cannot reach the app, and CRS is
# noisiest on logged-in app traffic.
#
# Computed from the live Ingresses at plan time, so a new public host without
# Authentik is covered on the next traefik apply. A host qualifies only if NONE
# of its Ingresses carries an Authentik forward-auth middleware (a host with one
# unauthenticated path carve-out next to an Authentik-gated main path stays
# out), it is not LAN-only (home-lans-only middleware or a .lan name), and it is
# not excluded below. IngressRoutes are not read; their hosts get the default
# listener.
#
# One query per namespace: with namespace omitted, kubernetes_resources lists
# only "default" for a namespaced kind (provider 3.3.0, datasource.go), and it
# has no all-namespaces option.
data "kubernetes_all_namespaces" "all" {}

data "kubernetes_resources" "ingresses" {
  for_each    = toset(data.kubernetes_all_namespaces.all.namespaces)
  api_version = "networking.k8s.io/v1"
  kind        = "Ingress"
  namespace   = each.key
}

locals {
  # Hosts that must never reach the CRS listener, with the reason for each.
  #
  # The pre-launch replay (2026-10-02: 322,883 unique requests from a week of
  # traffic on the then-52 qualifying hosts, plus realistic request bodies)
  # showed CRS cannot tell attack payloads from the normal content of hosts
  # whose job is carrying code, chat, notes, SQL or arbitrary secrets. Those
  # keep virtual patching on the default listener. Every other replay block was
  # a probe, apart from two paths handled by rule exclusions in the crowdsec
  # values (viktor/crs-setup).
  appsec_crs_exclude_hosts = [
    # Skipped by the bouncer altogether (skipHosts / appsecSkipHosts).
    "authentik.viktorbarzin.me",
    "public-auth.viktorbarzin.me",
    "immich.viktorbarzin.me",
    # Code browser: 4,620 replay blocks on ordinary file paths (Dockerfile,
    # .gitignore, *.ini) via 930130, and search terms are code.
    "forgejo.viktorbarzin.me",
    # Secret values are arbitrary strings; a KV write holding a shell script
    # was blocked. Not an HTML/SQL app, and its CVEs stay virtually patched.
    "vault.viktorbarzin.me",
    # Free-text content: memories full of shell and SQL, chat messages,
    # webhook payloads, notifications, documents, notes, recipes, SQL queries.
    "claude-memory.viktorbarzin.me",
    "matrix.viktorbarzin.me",
    "n8n.viktorbarzin.me",
    "webhook.viktorbarzin.me",
    "ntfy.viktorbarzin.me",
    "novelapp.viktorbarzin.me",
    "affine.viktorbarzin.me",
    "dolt-workbench.viktorbarzin.me",
    "linkwarden.viktorbarzin.me",
    "tandoor.viktorbarzin.me",
    "recruiter-responder.viktorbarzin.me",
    "json.viktorbarzin.me",
  ]

  _ingress_host_rows = flatten([
    for ing in flatten([for q in data.kubernetes_resources.ingresses : q.objects if q.objects != null]) : [
      for rule in try(ing.spec.rules, []) : {
        host        = lower(try(rule.host, ""))
        middlewares = try(ing.metadata.annotations["traefik.ingress.kubernetes.io/router.middlewares"], "")
      } if try(rule.host, "") != ""
    ]
  ])

  _authentik_hosts = toset([
    for row in local._ingress_host_rows : row.host
    if strcontains(row.middlewares, "authentik-forward-auth")
  ])

  appsec_crs_hosts = sort(distinct([
    for row in local._ingress_host_rows : row.host
    if !strcontains(row.middlewares, "authentik-forward-auth")
    && !strcontains(row.middlewares, "home-lans-only")
    && !endswith(row.host, ".lan")
    && !contains(local._authentik_hosts, row.host)
    && !contains(local.appsec_crs_exclude_hosts, row.host)
  ]))
}
