variable "tier" { type = string }

resource "kubernetes_namespace" "crowdsec" {
  metadata {
    name = "reloader"
    labels = {
      tier = var.tier
    }
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
