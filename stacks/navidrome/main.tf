variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
resource "kubernetes_namespace" "navidrome" {
  metadata {
    name = "navidrome"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
}

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "navidrome-secrets"
      namespace = "navidrome"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "navidrome-secrets"
      }
      dataFrom = [{
        extract = {
          key = "navidrome"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.navidrome]
}

data "kubernetes_secret" "eso_secrets" {
  metadata {
    name      = "navidrome-secrets"
    namespace = kubernetes_namespace.navidrome.metadata[0].name
  }
  depends_on = [kubernetes_manifest.external_secret]
}

locals {
  homepage_credentials = jsondecode(data.kubernetes_secret.eso_secrets.data["homepage_credentials"])
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.navidrome.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_persistent_volume_claim" "data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "navidrome-data-proxmox"
    namespace = kubernetes_namespace.navidrome.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}

module "nfs_music" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "navidrome-music"
  namespace  = kubernetes_namespace.navidrome.metadata[0].name
  nfs_server = "192.168.1.13"
  nfs_path   = "/volume1/music"
}

module "nfs_lidarr_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "navidrome-lidarr-host"
  namespace  = kubernetes_namespace.navidrome.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/servarr/lidarr"
}

module "nfs_freedify_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "navidrome-freedify-host"
  namespace  = kubernetes_namespace.navidrome.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/freedify-music"
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
          volume_mount {
            name       = "freedify"
            mount_path = "/freedify-music"
            read_only  = true
          }
          env {
            name  = "ND_SCANSCHEDULE"
            value = "0"
          }
          port {
            name           = "http"
            container_port = 4533
            protocol       = "TCP"
          }
          resources {
            requests = {
              cpu    = "15m"
              memory = "256Mi"
            }
            limits = {
              memory = "384Mi"
            }
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data_proxmox.metadata[0].name
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
            claim_name = module.nfs_lidarr_host.claim_name
          }
        }
        volume {
          name = "freedify"
          persistent_volume_claim {
            claim_name = module.nfs_freedify_host.claim_name
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
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.navidrome.metadata[0].name
  name            = "navidrome"
  tls_secret_name = var.tls_secret_name
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
