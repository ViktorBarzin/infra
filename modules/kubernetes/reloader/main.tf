resource "helm_release" "reloader" {
  namespace        = "reloader"
  create_namespace = true
  name             = "reloader"

  repository = "https://stakater.github.io/stakater-charts"
  chart      = "reloader"
}
