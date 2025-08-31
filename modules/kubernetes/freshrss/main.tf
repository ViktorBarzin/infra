variable "tls_secret_name" {}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "freshrss"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_namespace" "immich" {
  metadata {
    name = "freshrss"
  }
}


resource "kubernetes_deployment" "freshrss" {
  metadata {
    name      = "freshrss"
    namespace = "freshrss"
    labels = {
      app                             = "freshrss"
      "kubernetes.io/cluster-service" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "freshrss"
      }
    }
    template {
      metadata {
        labels = {
          app                             = "freshrss"
          "kubernetes.io/cluster-service" = "true"
        }
      }
      spec {

        container {
          name  = "freshrss"
          image = "freshrss/freshrss"
          env {
            name  = "CRON_MIN"
            value = "0,30"
          }
          env {
            name  = "BASE_URL"
            value = "https://rss.viktorbarzin.me"
          }
          env {
            name  = "PUBLISHED_PORT"
            value = 80
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/www/FreshRSS/data"
          }
          volume_mount {
            name       = "extensions"
            mount_path = "/var/www/FreshRSS/extensions"
          }
          port {
            name           = "http"
            container_port = 80
            protocol       = "TCP"
          }
        }
        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/freshrss/data"
            server = "10.0.10.15"
          }
        }
        volume {
          name = "extensions"
          nfs {
            path   = "/mnt/main/freshrss/extensions"
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "freshrss" {
  metadata {
    name      = "freshrss"
    namespace = "freshrss"
    labels = {
      "app" = "freshrss"
    }
  }

  spec {
    selector = {
      app = "freshrss"
    }
    port {
      port        = "80"
      target_port = "80"
    }
  }
}
module "ingress" {
  source          = "../ingress_factory"
  namespace       = "freshrss"
  name            = "rss"
  service_name    = "freshrss"
  tls_secret_name = var.tls_secret_name
}
