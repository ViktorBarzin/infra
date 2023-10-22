resource "helm_release" "prometheus" {
  namespace        = "localai"
  create_namespace = true
  name             = "localai"

  repository = "https://go-skynet.github.io/helm-charts/"
  chart      = "local-ai"
  #   version    = "15.0.2"

  values = [templatefile("${path.module}/prometheus_chart_values.tpl", { alertmanager_mail_pass = var.alertmanager_account_password, alertmanager_slack_api_url = var.alertmanager_slack_api_url })]
}
