variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
resource "kubernetes_namespace" "immich" {
  metadata {
    name = "freshrss"
    labels = {
      tier = local.tiers.aux
    }
  }
}

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "freshrss-secrets"
      namespace = "freshrss"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "freshrss-secrets"
      }
      dataFrom = [{
        extract = {
          key = "freshrss"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.immich]
}

data "kubernetes_secret" "eso_secrets" {
  metadata {
    name      = "freshrss-secrets"
    namespace = kubernetes_namespace.immich.metadata[0].name
  }
  depends_on = [kubernetes_manifest.external_secret]
}

locals {
  homepage_credentials = jsondecode(data.kubernetes_secret.eso_secrets.data["homepage_credentials"])
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = "freshrss"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_persistent_volume_claim" "data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "freshrss-data-proxmox"
    namespace = kubernetes_namespace.immich.metadata[0].name
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

resource "kubernetes_persistent_volume_claim" "extensions_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "freshrss-extensions-proxmox"
    namespace = kubernetes_namespace.immich.metadata[0].name
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
              memory = "256Mi"
            }
            limits = {
              memory = "256Mi"
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
          name = "extensions"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.extensions_proxmox.metadata[0].name
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
  dns_type        = "proxied"
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
    "gethomepage.dev/widget.username" = local.homepage_credentials["freshrss"]["username"]
    "gethomepage.dev/widget.password" = local.homepage_credentials["freshrss"]["password"]
  }
}
