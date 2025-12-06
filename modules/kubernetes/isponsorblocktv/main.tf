# https://github.com/dmunozv04/iSponsorBlockTV

resource "kubernetes_namespace" "isponsorblocktv" {
  metadata {
    name = "isponsorblocktv"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}
# Before running, setup config using 
# docker run --rm -it -v ./youtube:/app/data -e TERM=$TERM -e COLORTERM=$COLORTERM ghcr.io/dmunozv04/isponsorblocktv --setup

# Mute and skip ads for vermont smart tv
resource "kubernetes_deployment" "isponsorblocktv-vermont" {
  metadata {
    name      = "isponsorblocktv-vermont"
    namespace = "isponsorblocktv"
    labels = {
      app = "isponsorblocktv-vermont"
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

