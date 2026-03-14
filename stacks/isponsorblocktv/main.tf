variable "nfs_server" { type = string }

resource "kubernetes_namespace" "isponsorblocktv" {
  metadata {
    name = "isponsorblocktv"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.edge
    }
  }
}
# Before running, setup config using 
# docker run --rm -it -v ./youtube:/app/data -e TERM=$TERM -e COLORTERM=$COLORTERM ghcr.io/dmunozv04/isponsorblocktv --setup

module "nfs_data" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "isponsorblocktv-data"
  namespace  = kubernetes_namespace.isponsorblocktv.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/isponsorblocktv/vermont"
}

# Mute and skip ads for vermont smart tv
resource "kubernetes_deployment" "isponsorblocktv-vermont" {
  metadata {
    name      = "isponsorblocktv-vermont"
    namespace = kubernetes_namespace.isponsorblocktv.metadata[0].name
    labels = {
      app  = "isponsorblocktv-vermont"
      tier = local.tiers.edge
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "isponsorblocktv-vermont"
      }
    }
    template {
      metadata {
        labels = {
          app = "isponsorblocktv-vermont"
        }
      }
      spec {
        container {
          image = "ghcr.io/dmunozv04/isponsorblocktv"
          name  = "isponsorblocktv-vermont"
          volume_mount {
            name       = "data"
            mount_path = "/app/data"
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
