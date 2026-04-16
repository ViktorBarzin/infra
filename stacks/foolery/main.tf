variable "tls_secret_name" {
  type      = string
  sensitive = true
}

resource "kubernetes_namespace" "foolery" {
  metadata {
    name = "foolery"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.foolery.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# Service + Endpoints to reverse-proxy to Foolery at 10.0.10.10:3210
resource "kubernetes_service" "foolery" {
  metadata {
    name      = "foolery"
    namespace = kubernetes_namespace.foolery.metadata[0].name
    labels = {
      app = "foolery"
    }
  }

  spec {
    port {
      name        = "http"
      port        = 80
      target_port = 3210
    }
  }
}

resource "kubernetes_endpoints" "foolery" {
  metadata {
    name      = "foolery"
    namespace = kubernetes_namespace.foolery.metadata[0].name
  }

  subset {
    address {
      ip = "10.0.10.10"
    }
    port {
      name = "http"
      port = 3210
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.foolery.metadata[0].name
  name            = "foolery"
  tls_secret_name = var.tls_secret_name
  protected       = true
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Foolery"
    "gethomepage.dev/description"  = "Agent orchestration control room"
    "gethomepage.dev/icon"         = "mdi-robot"
    "gethomepage.dev/group"        = "AI"
    "gethomepage.dev/pod-selector" = ""
  }
}
