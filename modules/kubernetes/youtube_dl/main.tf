variable "tls_secret_name" {}

resource "kubernetes_namespace" "ytdlp" {
  metadata {
    name = "ytdlp"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.ytdlp.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "ytdlp" {
  # resource "kubernetes_daemonset" "technitium" {
  metadata {
    name      = "ytdlp"
    namespace = kubernetes_namespace.ytdlp.metadata[0].name
    labels = {
      app = "ytdlp"
    }
    annotations = {
      "diun.enable" = "true"
    }
  }
  spec {
    # strategy {
    #   type = "Recreate"
    # }
    # replicas = 1
    selector {
      match_labels = {
        app = "ytdlp"
      }
    }
    template {
      metadata {
        labels = {
          app = "ytdlp"
        }
      }
      spec {
        container {
          image = "tzahi12345/youtubedl-material:nightly"
          name  = "ytdlp"
          # resources {
          #   limits = {
          #     cpu    = "1"
          #     memory = "1Gi"
          #   }
          # requests = {
          #   cpu    = "1"
          #   memory = "1Gi"
          # }
          # }
          port {
            container_port = 17442
          }
          volume_mount {
            mount_path = "/app/appdata"
            name       = "data"
          }
          volume_mount {
            mount_path = "/app/audio"
            name       = "data"
          }
          volume_mount {
            mount_path = "/app/video"
            name       = "data"
          }
          volume_mount {
            mount_path = "/app/users"
            name       = "data"
          }
          volume_mount {
            mount_path = "/app/subscriptions"
            name       = "data"
          }
        }
        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/ytdlp"
            server = "10.0.10.15"
          }
        }
        # }
      }
    }
  }
}

resource "kubernetes_service" "ytdlp" {
  metadata {
    name      = "ytdlp"
    namespace = kubernetes_namespace.ytdlp.metadata[0].name
    labels = {
      "app" = "ytdlp"
    }
  }

  spec {
    selector = {
      app = "ytdlp"
    }
    port {
      name        = "ytdlp"
      port        = 80
      target_port = 17442
      protocol    = "TCP"
    }
  }
}
module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.ytdlp.metadata[0].name
  name            = "ytdlp"
  tls_secret_name = var.tls_secret_name
  host            = "yt"
  extra_annotations = {
    "nginx.ingress.kubernetes.io/client-max-body-size" : "0"
    "nginx.ingress.kubernetes.io/proxy-body-size" : "0",
  }
}
