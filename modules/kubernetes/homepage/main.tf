variable "tls_secret_name" {}
variable "tier" { type = string }

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.homepage.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_namespace" "homepage" {
  metadata {
    name = "homepage"
    labels = {
      "istio-injection" : "disabled"
      tier = var.tier
    }
  }
}

resource "helm_release" "homepage" {
  namespace        = kubernetes_namespace.homepage.metadata[0].name
  create_namespace = false
  name             = "homepage"
  atomic           = true

  repository = "http://jameswynn.github.io/helm-charts"
  chart      = "homepage"

  values = [templatefile("${path.module}/values.yaml", { tls_secret_name = var.tls_secret_name })]
}
