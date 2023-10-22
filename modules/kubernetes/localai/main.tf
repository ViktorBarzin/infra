variable "tls_secret_name" {}

resource "helm_release" "prometheus" {
  namespace        = "localai"
  create_namespace = true
  name             = "localai"

  repository = "https://go-skynet.github.io/helm-charts/"
  chart      = "local-ai"
  #   version    = "15.0.2"
  #   atomic          = true
  #   cleanup_on_fail = true

  values = [templatefile("${path.module}/chart_values.tpl", { tls_secret = var.tls_secret_name })]
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "localai"
  tls_secret_name = var.tls_secret_name
}
