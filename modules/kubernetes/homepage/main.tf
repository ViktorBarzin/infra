
variable "tls_secret_name" {}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "homepage"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_namespace" "homepage" {
  metadata {
    name = "homepage"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

resource "helm_release" "homepage" {
  namespace        = "homepage"
  create_namespace = false
  name             = "homepage"
  atomic           = true

  repository = "http://jameswynn.github.io/helm-charts"
  chart      = "homepage"

  values = [templatefile("${path.module}/values.yaml", { tls_secret_name = var.tls_secret_name })]
}
