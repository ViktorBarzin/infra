variable "tls_secret_name" {
  type      = string
  sensitive = true
}


resource "kubernetes_namespace" "cyberchef" {
  metadata {
    name = "cyberchef"
    labels = {
      tier = local.tiers.aux
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.cyberchef.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "cyberchef" {
  metadata {
    name      = "cyberchef"
    namespace = kubernetes_namespace.cyberchef.metadata[0].name
    labels = {
      app  = "cyberchef"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "RollingUpdate"
    }
    selector {
      match_labels = {
        app = "cyberchef"
      }
    }
    template {
      metadata {
        labels = {
          app = "cyberchef"
        }
        annotations = {
          "diun.enable"       = "true"
          "diun.include_tags" = "^v\\d+\\.\\d+\\.\\d+$"
        }
      }
      spec {
        container {
          image = "mpepping/cyberchef:v9.55.0"
          name  = "cyberchef"

          port {
            container_port = 8000
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "cyberchef" {
  metadata {
    name      = "cc"
    namespace = kubernetes_namespace.cyberchef.metadata[0].name
    labels = {
      "app" = "cyberchef"
    }
  }

  spec {
    selector = {
      app = "cyberchef"
    }
    port {
      name        = "http"
      target_port = 8000
      port        = 80
    }
  }
}


module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.cyberchef.metadata[0].name
  name            = "cc"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "CyberChef"
    "gethomepage.dev/description"  = "Data transformation toolkit"
    "gethomepage.dev/icon"         = "cyberchef.png"
    "gethomepage.dev/group"        = "Development & CI"
    "gethomepage.dev/pod-selector" = ""
  }
}
