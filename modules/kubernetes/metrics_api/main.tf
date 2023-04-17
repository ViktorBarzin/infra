variable "tls_secret_name" {}

# resource "kubernetes_namespace" "metrics" {
#   metadata {
#     name = "metrics"
#   }
# }

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "metrics"
  tls_secret_name = var.tls_secret_name
}

resource "helm_release" "metrics_api" {
  namespace        = "metrics"
  create_namespace = true
  name             = "metrics-server"

  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"

  #   values = [templatefile("${path.module}/prometheus_chart_values.tpl", { alertmanager_mail_pass = var.alertmanager_account_password, alertmanager_slack_api_url = var.alertmanager_slack_api_url })]
}
