variable "namespace" { type = string }
variable "tls_secret_name" {}
variable "tls_crt" {
  default = ""
}
variable "tls_key" {
  default = ""
}

resource "kubernetes_secret" "tls_secret" {
  metadata {
    name      = var.tls_secret_name
    namespace = var.namespace
  }
  data = {
    # Cannot set default function in variable so use default behaviour here
    "tls.crt" = var.tls_crt == "" ? file("${path.root}/secrets/fullchain.pem") : var.tls_crt
    "tls.key" = var.tls_key == "" ? file("${path.root}/secrets/privkey.pem") : var.tls_key
  }
  type = "kubernetes.io/tls"
}
