variable namespace {}
variable tls_secret_name {}
variable tls_crt {}
variable tls_key {}

resource "kubernetes_secret" "tls_secret" {
  metadata {
    name      = var.tls_secret_name
    namespace = var.namespace
  }
  data = {
    "tls.crt" = var.tls_crt
    "tls.key" = var.tls_key
  }
  type = "kubernetes.io/tls"
}
