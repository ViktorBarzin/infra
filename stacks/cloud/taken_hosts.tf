# Hosts the homelab already routes, for cloud-managed-ingress (access_rules.tf,
# local.cloud_taken_hosts_marker). Traefik ranks routers by rule length, so a
# Project Ingress for nextcloud.viktorbarzin.me with a longer path would take
# that path from the homelab router, and with it the domain-wide forward-auth
# cookies. A ValidatingAdmissionPolicy cannot list other objects, so
# local.cloud_taken_hosts (one key per host, the value naming where the host is
# routed) is written into the policy itself as a CEL map literal. Not a
# ConfigMap parameter: calico-apiserver runs every admission policy too, and a
# paramKind policy makes it unready (access_rules.tf, "No policy here takes a
# parameter").
#
# Computed from the live Ingresses and IngressRoutes at plan time, the way
# stacks/traefik crs-hosts.tf computes its host list. A host added to the
# homelab after the last cloud apply is missing until the next one; the nightly
# drift plan shows it as a change to cloud-managed-ingress, and the
# reconciler's own taken-host check (its cluster-wide read on both kinds)
# covers the gap.
#
# Only hosts a Project could ask for are kept (one label under the base
# domain, cloud-managed-ingress refuses the rest), and managed namespaces
# (p-*) are skipped, so a Project's own hosts never block it.

# One query per namespace: with namespace omitted, kubernetes_resources lists
# only "default" for a namespaced kind (provider 3.3.0).
data "kubernetes_all_namespaces" "all" {}

locals {
  cloud_homelab_namespaces = toset([for ns in data.kubernetes_all_namespaces.all.namespaces : ns if !startswith(ns, "p-")])
}

data "kubernetes_resources" "ingresses" {
  for_each    = local.cloud_homelab_namespaces
  api_version = "networking.k8s.io/v1"
  kind        = "Ingress"
  namespace   = each.key
}

data "kubernetes_resources" "ingressroutes" {
  for_each    = local.cloud_homelab_namespaces
  api_version = "traefik.io/v1alpha1"
  kind        = "IngressRoute"
  namespace   = each.key
}

locals {
  _cloud_route_rows = concat(
    flatten([
      for ing in flatten([for q in data.kubernetes_resources.ingresses : q.objects if q.objects != null]) : concat(
        [for r in try(ing.spec.rules, []) : { host = lower(try(r.host, "")), from = "ingress ${ing.metadata.namespace}/${ing.metadata.name}" }],
        flatten([for t in try(ing.spec.tls, []) : [for h in try(t.hosts, []) : { host = lower(h), from = "ingress ${ing.metadata.namespace}/${ing.metadata.name}" }]]),
      )
    ]),
    # Host(`a`) and Host(`a`, `b`) in each route's match; HostRegexp hosts
    # cannot be listed.
    flatten([
      for ir in flatten([for q in data.kubernetes_resources.ingressroutes : q.objects if q.objects != null]) : [
        for h in flatten([for rt in try(ir.spec.routes, []) : flatten(regexall("Host\\(([^)]*)\\)", try(rt.match, "")))]) : [
          for name in regexall("`([^`]+)`", h) : { host = lower(name[0]), from = "ingressroute ${ir.metadata.namespace}/${ir.metadata.name}" }
        ]
      ]
    ]),
  )

  cloud_taken_host_sources = {
    for row in local._cloud_route_rows : row.host => row.from...
    if can(regex(local.cloud_ingress_host_re, row.host))
  }

  # Read by local.cloud_admission_policies_applied in access_rules.tf.
  cloud_taken_hosts = { for host, from in local.cloud_taken_host_sources : host => join(", ", sort(distinct(from))) }
}
