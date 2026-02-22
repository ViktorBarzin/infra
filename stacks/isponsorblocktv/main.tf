locals {
  tiers = {
    core    = "0-core"
    cluster = "1-cluster"
    gpu     = "2-gpu"
    edge    = "3-edge"
    aux     = "4-aux"
  }
}

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
        }
        volume {
          name = "data"
          nfs {
            server = "10.0.10.15"
            path   = "/mnt/main/isponsorblocktv/vermont"
          }
        }
      }
    }
  }
}
