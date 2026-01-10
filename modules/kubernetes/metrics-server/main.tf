variable "tls_secret_name" {}
variable "tier" { type = string }

resource "kubernetes_namespace" "metrics-server" {
  metadata {
    name = "metrics-server"
    labels = {
      tier = var.tier
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.metrics-server.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "helm_release" "metrics-server" {
  namespace        = kubernetes_namespace.metrics-server.metadata[0].name
  create_namespace = false
  name             = "metrics-server"
  atomic           = true

  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"

  values = [templatefile("${path.module}/values.yaml", {})]
}
