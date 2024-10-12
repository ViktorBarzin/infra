variable "tls_secret_name" {}

resource "kubernetes_namespace" "metrics-server" {
  metadata {
    name = "metrics-server"
    # labels = {
    #   "istio-injection" : "enabled"
    # }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "metrics-server"
  tls_secret_name = var.tls_secret_name

  depends_on = [kubernetes_namespace.metrics-server]
}

resource "helm_release" "metrics-server" {
  namespace        = "metrics-server"
  create_namespace = false
  name             = "metrics-server"
  atomic           = true

  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"

  values = [templatefile("${path.module}/values.yaml", {})]

  depends_on = [kubernetes_namespace.metrics-server]
}
