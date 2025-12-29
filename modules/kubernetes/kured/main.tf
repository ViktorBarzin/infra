variable "tls_secret_name" {}
variable "notify_url" {}

resource "kubernetes_namespace" "kured" {
  metadata {
    name = "kured"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.kured.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "helm_release" "kured" {
  namespace        = kubernetes_namespace.kured.metadata[0].name
  create_namespace = false
  name             = "kured"

  repository = "https://kubereboot.github.io/charts"
  chart      = "kured"

  values = [templatefile("${path.module}/values.yaml", { notify_url : var.notify_url })]
  atomic = true

  depends_on = [kubernetes_namespace.kured]
}
