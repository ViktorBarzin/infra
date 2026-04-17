variable "tls_secret_name" {
  type      = string
  sensitive = true
}


resource "kubernetes_namespace" "networking-toolbox" {
  metadata {
    name = "networking-toolbox"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.networking-toolbox.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "networking-toolbox" {
  metadata {
    name      = "networking-toolbox"
    namespace = kubernetes_namespace.networking-toolbox.metadata[0].name
    labels = {
      app  = "networking-toolbox"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "networking-toolbox"
      }
    }
    template {
      metadata {
        labels = {
          app = "networking-toolbox"
        }
        annotations = {
          "diun.enable"       = "true"
          "diun.include_tags" = "^\\d+\\.\\d+\\.\\d+$"
        }
      }
      spec {
        container {
          image = "lissy93/networking-toolbox:1.6.0"
          name  = "networking-toolbox"
          port {
            container_port = 3000
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "128Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "networking-toolbox" {
  metadata {
    name      = "networking-toolbox"
    namespace = kubernetes_namespace.networking-toolbox.metadata[0].name
    labels = {
      "app" = "networking-toolbox"
    }
  }

  spec {
    selector = {
      app = "networking-toolbox"
    }
    port {
      name        = "http"
      port        = "80"
      target_port = "3000"
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.networking-toolbox.metadata[0].name
  name            = "networking-toolbox"
  tls_secret_name = var.tls_secret_name
  protected       = true
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Networking Toolbox"
    "gethomepage.dev/description"  = "Network diagnostic tools"
    "gethomepage.dev/icon"         = "mdi-lan"
    "gethomepage.dev/group"        = "Development & CI"
    "gethomepage.dev/pod-selector" = ""
  }
}
