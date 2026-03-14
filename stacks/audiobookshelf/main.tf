variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "audiobookshelf"
}

locals {
  homepage_credentials = jsondecode(data.vault_kv_secret_v2.secrets.data["homepage_credentials"])
}


resource "kubernetes_namespace" "audiobookshelf" {
  metadata {
    name = "audiobookshelf"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.audiobookshelf.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

module "nfs_audiobooks" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "audiobookshelf-audiobooks"
  namespace  = kubernetes_namespace.audiobookshelf.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/audiobookshelf/audiobooks"
}

module "nfs_podcasts" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "audiobookshelf-podcasts"
  namespace  = kubernetes_namespace.audiobookshelf.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/audiobookshelf/podcasts"
}

module "nfs_config" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "audiobookshelf-config"
  namespace  = kubernetes_namespace.audiobookshelf.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/audiobookshelf/config"
}

module "nfs_metadata" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "audiobookshelf-metadata"
  namespace  = kubernetes_namespace.audiobookshelf.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/audiobookshelf/metadata"
}

resource "kubernetes_deployment" "audiobookshelf" {
  metadata {
    name      = "audiobookshelf"
    namespace = kubernetes_namespace.audiobookshelf.metadata[0].name
    labels = {
      app  = "audiobookshelf"
      tier = local.tiers.aux
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
          liveness_probe {
            http_get {
              path = "/healthcheck"
              port = 80
            }
            initial_delay_seconds = 15
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 5
          }
          readiness_probe {
            http_get {
              path = "/healthcheck"
              port = 80
            }
            initial_delay_seconds = 5
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 3
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
          resources {
            requests = {
              cpu    = "15m"
              memory = "64Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }
        }
        volume {
          name = "audiobooks"
          persistent_volume_claim {
            claim_name = module.nfs_audiobooks.claim_name
          }
        }
        volume {
          name = "podcasts"
          persistent_volume_claim {
            claim_name = module.nfs_podcasts.claim_name
          }
        }
        volume {
          name = "config"
          persistent_volume_claim {
            claim_name = module.nfs_config.claim_name
          }
        }
        volume {
          name = "metadata"
          persistent_volume_claim {
            claim_name = module.nfs_metadata.claim_name
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
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.audiobookshelf.metadata[0].name
  name            = "audiobookshelf"
  tls_secret_name = var.tls_secret_name
  rybbit_site_id  = "b38fda4285df"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Audiobookshelf"
    "gethomepage.dev/description"  = "Audiobook library"
    "gethomepage.dev/icon"         = "audiobookshelf.png"
    "gethomepage.dev/group"        = "Media & Entertainment"
    "gethomepage.dev/pod-selector" = ""
    "gethomepage.dev/widget.type"  = "audiobookshelf"
    "gethomepage.dev/widget.url"   = "http://audiobookshelf.audiobookshelf.svc.cluster.local"
    "gethomepage.dev/widget.key"   = local.homepage_credentials["audiobookshelf"]["token"]
  }
}
