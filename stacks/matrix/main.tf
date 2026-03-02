variable "tls_secret_name" { type = string }
variable "nfs_server" { type = string }


resource "kubernetes_namespace" "matrix" {
  metadata {
    name = "matrix"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.matrix.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

module "nfs_data" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "matrix-data"
  namespace  = kubernetes_namespace.matrix.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/matrix"
}

resource "kubernetes_deployment" "matrix" {
  metadata {
    name      = "matrix"
    namespace = kubernetes_namespace.matrix.metadata[0].name
    labels = {
      app  = "matrix"
      tier = local.tiers.aux
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
          persistent_volume_claim {
            claim_name = module.nfs_data.claim_name
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
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.matrix.metadata[0].name
  name            = "matrix"
  tls_secret_name = var.tls_secret_name
}
