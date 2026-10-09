# Traefik's traefik.io CRDs, vendored from the Helm chart this stack pins
# (traefik 41.7.0, appVersion v3.7.14) and applied here. 40.2.0 -> 41.7.0 only
# added Middleware errors.errorRequestHeaders; no property removed.
#
# WHY: Helm installs a chart's crds/ directory only on first install and never
# upgrades it, so the cluster kept the CRDs from 2026-02-07 while the Traefik
# binary moved on. Found 2026-10-02 when ForwardAuth's maxResponseBodySize
# (understood by v3.7.1, warned about on every request) did not exist in the
# installed Middleware schema at all. A server-side dry run and a field-by-field
# diff showed the 40.2.0 schemas are purely additive over the live ones: no
# property removed in any of the 10 CRDs.
#
# WHEN THE CHART IS BUMPED: re-vendor these files from the new chart's crds/
# (only traefik.io_*.yaml; the hub.traefik.io CRDs are unused here), diff the
# schemas for removed properties first, then apply.
#
# Server-side apply with force_conflicts, because Helm is the existing field
# manager. prevent_destroy, because deleting a CRD deletes every object of its
# kind: one stray destroy would remove every Middleware and IngressRoute.
resource "kubectl_manifest" "traefik_crds" {
  for_each = fileset("${path.module}/crds", "traefik.io_*.yaml")

  yaml_body         = trimprefix(file("${path.module}/crds/${each.value}"), "---\n")
  server_side_apply = true
  force_conflicts   = true
  wait              = true

  lifecycle {
    prevent_destroy = true
  }
}
