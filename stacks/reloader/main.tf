resource "kubernetes_namespace" "crowdsec" {
  metadata {
    name = "reloader"
    labels = {
      tier = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}
resource "helm_release" "reloader" {
  namespace        = kubernetes_namespace.crowdsec.metadata[0].name
  create_namespace = false
  name             = "reloader"
  atomic           = true

  repository = "https://stakater.github.io/stakater-charts"
  chart      = "reloader"
}
