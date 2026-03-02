variable "tls_secret_name" { type = string }
variable "nfs_server" { type = string }


resource "kubernetes_namespace" "stirling-pdf" {
  metadata {
    name = "stirling-pdf"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.stirling-pdf.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

module "nfs_configs" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "stirling-pdf-configs"
  namespace  = kubernetes_namespace.stirling-pdf.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/stirling-pdf"
}

resource "kubernetes_deployment" "stirling-pdf" {
  metadata {
    name      = "stirling-pdf"
    namespace = kubernetes_namespace.stirling-pdf.metadata[0].name
    labels = {
      app  = "stirling-pdf"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "stirling-pdf"
      }
    }
    template {
      metadata {
        labels = {
          app = "stirling-pdf"
        }
      }
      spec {
        container {
          image = "stirlingtools/stirling-pdf:latest"
          name  = "stirling-pdf"
          resources {
            requests = {
              cpu    = "100m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "2"
              memory = "2Gi"
            }
          }

          port {
            container_port = 8080
          }
          volume_mount {
            name       = "configs"
            mount_path = "/configs"
          }
        }
        volume {
          name = "configs"
          persistent_volume_claim {
            claim_name = module.nfs_configs.claim_name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "stirling-pdf" {
  metadata {
    name      = "stirling-pdf"
    namespace = kubernetes_namespace.stirling-pdf.metadata[0].name
    labels = {
      "app" = "stirling-pdf"
    }
  }

  spec {
    selector = {
      app = "stirling-pdf"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.stirling-pdf.metadata[0].name
  name            = "stirling-pdf"
  tls_secret_name = var.tls_secret_name
  rybbit_site_id  = "a55ac54ec749"
}
