variable "tls_secret_name" { type = string }
variable "nfs_server" { type = string }


module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = "freshrss"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_namespace" "immich" {
  metadata {
    name = "freshrss"
    labels = {
      tier = local.tiers.aux
    }
  }
}


resource "kubernetes_deployment" "freshrss" {
  metadata {
    name      = "freshrss"
    namespace = "freshrss"
    labels = {
      app                             = "freshrss"
      "kubernetes.io/cluster-service" = "true"
      tier                            = local.tiers.aux
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
          resources {
            requests = {
              cpu    = "15m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "250m"
              memory = "256Mi"
            }
          }
        }
        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/freshrss/data"
            server = var.nfs_server
          }
        }
        volume {
          name = "extensions"
          nfs {
            path   = "/mnt/main/freshrss/extensions"
            server = var.nfs_server
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
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = "freshrss"
  name            = "rss"
  service_name    = "freshrss"
  tls_secret_name = var.tls_secret_name
}
