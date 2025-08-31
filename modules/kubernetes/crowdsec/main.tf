variable "tls_secret_name" {}
variable "homepage_username" {}
variable "homepage_password" {}
variable "db_password" {}
variable "enroll_key" {}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "crowdsec"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_namespace" "crowdsec" {
  metadata {
    name = "crowdsec"
  }
}

resource "helm_release" "crowdsec" {
  namespace        = "crowdsec"
  create_namespace = true
  name             = "crowdsec"
  atomic           = true
  version          = "0.19.4"

  repository = "https://crowdsecurity.github.io/helm-charts"
  chart      = "crowdsec"

  values  = [templatefile("${path.module}/values.yaml", { homepage_username = var.homepage_username, homepage_password = var.homepage_password, DB_PASSWORD = var.db_password, ENROLL_KEY = var.enroll_key })]
  timeout = 3600
}
