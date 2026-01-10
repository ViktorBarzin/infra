variable "tls_secret_name" {}
variable "tier" { type = string }

resource "kubernetes_namespace" "audiobookshelf" {
  metadata {
    name = "audiobookshelf"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.audiobookshelf.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "audiobookshelf" {
  metadata {
    name      = "audiobookshelf"
    namespace = kubernetes_namespace.audiobookshelf.metadata[0].name
    labels = {
      app  = "audiobookshelf"
      tier = var.tier
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "audiobookshelf"
      }
    }
    template {
      metadata {
        labels = {
          app = "audiobookshelf"
        }
      }
      spec {
        container {
          image = "ghcr.io/advplyr/audiobookshelf:2.32.1"
          name  = "audiobookshelf"

          port {
            container_port = 80
          }
          volume_mount {
            name       = "audiobooks"
            mount_path = "/audiobooks"
          }
          volume_mount {
            name       = "podcasts"
            mount_path = "/podcasts"
          }
          volume_mount {
            name       = "config"
            mount_path = "/config"
          }
          volume_mount {
            name       = "metadata"
            mount_path = "/metadata"
          }
        }
        volume {
          name = "audiobooks"
          nfs {
            path   = "/mnt/main/audiobookshelf/audiobooks"
            server = "10.0.10.15"
          }
        }
        volume {
          name = "podcasts"
          nfs {
            path   = "/mnt/main/audiobookshelf/podcasts"
            server = "10.0.10.15"
          }
        }
        volume {
          name = "config"
          nfs {
            path   = "/mnt/main/audiobookshelf/config"
            server = "10.0.10.15"
          }
        }
        volume {
          name = "metadata"
          nfs {
            path   = "/mnt/main/audiobookshelf/metadata"
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "audiobookshelf" {
  metadata {
    name      = "audiobookshelf"
    namespace = kubernetes_namespace.audiobookshelf.metadata[0].name
    labels = {
      "app" = "audiobookshelf"
    }
  }

  spec {
    selector = {
      app = "audiobookshelf"
    }
    port {
      name        = "http"
      target_port = 80
      port        = 80
      protocol    = "TCP"
    }
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.audiobookshelf.metadata[0].name
  name            = "audiobookshelf"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "nginx.ingress.kubernetes.io/proxy-body-size" : "0",
    "nginx.ingress.kubernetes.io/client-max-body-size" : "0"
  }
  rybbit_site_id = "b38fda4285df"
}

