variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
variable "homepage_credentials" {
  type      = map(any)
  sensitive = true
}


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

module "nfs_data" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "freshrss-data"
  namespace  = kubernetes_namespace.immich.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/freshrss/data"
}

module "nfs_extensions" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "freshrss-extensions"
  namespace  = kubernetes_namespace.immich.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/freshrss/extensions"
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
              memory = "256Mi"
            }
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = module.nfs_data.claim_name
          }
        }
        volume {
          name = "extensions"
          persistent_volume_claim {
            claim_name = module.nfs_extensions.claim_name
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
  extra_annotations = {
    "gethomepage.dev/enabled"         = "true"
    "gethomepage.dev/name"            = "FreshRSS"
    "gethomepage.dev/description"     = "RSS feed reader"
    "gethomepage.dev/icon"            = "freshrss.png"
    "gethomepage.dev/group"           = "Productivity"
    "gethomepage.dev/pod-selector"    = ""
    "gethomepage.dev/widget.type"     = "freshrss"
    "gethomepage.dev/widget.url"      = "http://freshrss.freshrss.svc.cluster.local"
    "gethomepage.dev/widget.username" = var.homepage_credentials["freshrss"]["username"]
    "gethomepage.dev/widget.password" = var.homepage_credentials["freshrss"]["password"]
  }
}
