variable "tls_secret_name" {
  type      = string
  sensitive = true
}

resource "kubernetes_namespace" "terminal" {
  metadata {
    name = "terminal"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.terminal.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# Service + Endpoints to reverse-proxy to ttyd at 10.0.10.10:7681
resource "kubernetes_service" "terminal" {
  metadata {
    name      = "terminal"
    namespace = kubernetes_namespace.terminal.metadata[0].name
    labels = {
      app = "terminal"
    }
  }

  spec {
    port {
      name        = "http"
      port        = 80
      target_port = 7681
    }
  }
}

resource "kubernetes_endpoints" "terminal" {
  metadata {
    name      = "terminal"
    namespace = kubernetes_namespace.terminal.metadata[0].name
  }

  subset {
    address {
      ip = "10.0.10.10"
    }
    port {
      name = "http"
      port = 7681
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.terminal.metadata[0].name
  name            = "terminal"
  tls_secret_name = var.tls_secret_name
  protected       = true
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Terminal"
    "gethomepage.dev/description"  = "Web terminal (ttyd)"
    "gethomepage.dev/icon"         = "mdi-console"
    "gethomepage.dev/group"        = "Infrastructure"
    "gethomepage.dev/pod-selector" = ""
  }
}
