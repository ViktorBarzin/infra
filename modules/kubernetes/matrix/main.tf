variable "tls_secret_name" {}
variable "tier" { type = string }

resource "kubernetes_namespace" "matrix" {
  metadata {
    name = "matrix"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.matrix.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "matrix" {
  metadata {
    name      = "matrix"
    namespace = kubernetes_namespace.matrix.metadata[0].name
    labels = {
      app  = "matrix"
      tier = var.tier
    }
  }
  spec {
    replicas = 0
    selector {
      match_labels = {
        app = "matrix"
      }
    }
    template {
      metadata {
        labels = {
          app = "matrix"
        }
      }
      spec {
        container {
          image = "matrixdotorg/synapse:latest"
          name  = "matrix"
          port {
            container_port = 8008
          }
          env {
            name  = "SYNAPSE_SERVER_NAME"
            value = "matrix.viktorbarzin.me"
          }
          env {
            name  = "SYNAPSE_REPORT_STATS"
            value = "yes"
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
        }
        volume {
          name = "data"
          nfs {
            server = "10.0.10.15"
            path   = "/mnt/main/matrix"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "matrix" {
  metadata {
    name      = "matrix"
    namespace = kubernetes_namespace.matrix.metadata[0].name
    labels = {
      "app" = "matrix"
    }
  }

  spec {
    selector = {
      app = "matrix"
    }
    port {
      name        = "http"
      port        = "80"
      target_port = "8008"
    }
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.matrix.metadata[0].name
  name            = "matrix"
  tls_secret_name = var.tls_secret_name
}
