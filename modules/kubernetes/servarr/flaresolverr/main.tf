variable "tls_secret_name" {}

resource "kubernetes_deployment" "flaresolverr" {
  metadata {
    name      = "flaresolverr"
    namespace = "servarr"
    labels = {
      app = "flaresolverr"
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "flaresolverr"
      }
    }
    template {
      metadata {
        labels = {
          app = "flaresolverr"
        }
      }
      spec {
        container {
          image = "ghcr.io/flaresolverr/flaresolverr:latest"
          name  = "flaresolverr"

          port {
            container_port = 8191
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "flaresolverr" {
  metadata {
    name      = "flaresolverr"
    namespace = "servarr"
    labels = {
      app = "flaresolverr"
    }
  }

  spec {
    selector = {
      app = "flaresolverr"
    }
    port {
      name        = "http"
      target_port = 8191
      port        = 80
    }
  }
}

module "ingress" {
  source          = "../../ingress_factory"
  namespace       = "servarr"
  name            = "flaresolverr"
  tls_secret_name = var.tls_secret_name
  protected       = true
  #   extra_annotations = {
  #     "nginx.ingress.kubernetes.io/proxy-body-size" : "1G" // allow uploading .torrent files
  #   }

}
