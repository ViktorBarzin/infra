variable "tls_secret_name" {
  type = string
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
      }
      spec {
        container {
          image = "mpepping/cyberchef:latest"
          name  = "cyberchef"

          port {
            container_port = 8000
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              cpu    = "100m"
              memory = "128Mi"
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
  namespace       = kubernetes_namespace.cyberchef.metadata[0].name
  name            = "cc"
  tls_secret_name = var.tls_secret_name
  rybbit_site_id  = "7c460afc68c4"
}
