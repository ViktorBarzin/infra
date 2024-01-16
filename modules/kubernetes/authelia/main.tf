variable "tls_secret_name" {}

resource "kubernetes_namespace" "authelia" {
  metadata {
    name = "authelia"
    labels = {
      "istio-injection" : "enabled"
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "authelia"
  tls_secret_name = var.tls_secret_name
}

resource "helm_release" "authelia" {
  namespace        = "authelia"
  create_namespace = true
  name             = "authelia"
  atomic           = true

  repository = "https://charts.authelia.com"
  chart      = "authelia"

  values = [templatefile("${path.module}/values.yaml", {})]
}
