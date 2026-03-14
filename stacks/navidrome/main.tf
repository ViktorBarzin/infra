variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "navidrome"
}

locals {
  homepage_credentials = jsondecode(data.vault_kv_secret_v2.secrets.data["homepage_credentials"])
}


resource "kubernetes_namespace" "navidrome" {
  metadata {
    name = "navidrome"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.navidrome.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

module "nfs_data" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "navidrome-data"
  namespace  = kubernetes_namespace.navidrome.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/navidrome"
}

module "nfs_music" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "navidrome-music"
  namespace  = kubernetes_namespace.navidrome.metadata[0].name
  nfs_server = "192.168.1.13"
  nfs_path   = "/volume1/music"
}

module "nfs_lidarr" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "navidrome-lidarr"
  namespace  = kubernetes_namespace.navidrome.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/servarr/lidarr"
}

resource "kubernetes_deployment" "navidrome" {
  metadata {
    name      = "navidrome"
    namespace = kubernetes_namespace.navidrome.metadata[0].name
    labels = {
      app  = "navidrome"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "navidrome"
      }
    }
    template {
      metadata {
        labels = {
          app = "navidrome"
        }
      }
      spec {
        container {
          name  = "navidrome"
          image = "deluan/navidrome:latest"
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          volume_mount {
            name       = "music"
            mount_path = "/music"
            read_only  = true
          }
          volume_mount {
            name       = "lidarr"
            mount_path = "/lidarr"
            read_only  = true
          }
          port {
            name           = "http"
            container_port = 4533
            protocol       = "TCP"
          }
          resources {
            requests = {
              cpu    = "15m"
              memory = "64Mi"
            }
            limits = {
              memory = "384Mi"
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
          name = "music"
          persistent_volume_claim {
            claim_name = module.nfs_music.claim_name
          }
        }
        volume {
          name = "lidarr"
          persistent_volume_claim {
            claim_name = module.nfs_lidarr.claim_name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "navidrome" {
  metadata {
    name      = "navidrome"
    namespace = kubernetes_namespace.navidrome.metadata[0].name
    labels = {
      "app" = "navidrome"
    }
  }

  spec {
    selector = {
      app = "navidrome"
    }
    port {
      port        = "80"
      target_port = "4533"
    }
  }
}
module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.navidrome.metadata[0].name
  name            = "navidrome"
  tls_secret_name = var.tls_secret_name
  rybbit_site_id  = "8a3844ff75ba"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Navidrome"
    "gethomepage.dev/description"  = "Music streaming"
    "gethomepage.dev/icon"         = "navidrome.png"
    "gethomepage.dev/group"        = "Media & Entertainment"
    "gethomepage.dev/pod-selector" = ""
    "gethomepage.dev/widget.type"  = "navidrome"
    "gethomepage.dev/widget.url"   = "http://navidrome.navidrome.svc.cluster.local"
    "gethomepage.dev/widget.user"  = local.homepage_credentials["navidrome"]["user"]
    "gethomepage.dev/widget.token" = local.homepage_credentials["navidrome"]["token"]
    "gethomepage.dev/widget.salt"  = local.homepage_credentials["navidrome"]["salt"]
  }
}
