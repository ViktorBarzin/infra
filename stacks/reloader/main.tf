locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

resource "kubernetes_namespace" "crowdsec" {
  metadata {
    name = "reloader"
    labels = {
      tier = local.tiers.aux
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
