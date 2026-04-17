variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }

resource "kubernetes_namespace" "ebooks" {
  metadata {
    name = "ebooks"
    labels = {
      tier = local.tiers.edge
    }
  }
}

# ExternalSecrets for all three sources
resource "kubernetes_manifest" "calibre_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "calibre-secrets"
      namespace = "ebooks"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "calibre-secrets"
      }
      dataFrom = [{
        extract = {
          key = "calibre"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.ebooks]
}

resource "kubernetes_manifest" "audiobookshelf_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "audiobookshelf-secrets"
      namespace = "ebooks"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "audiobookshelf-secrets"
      }
      dataFrom = [{
        extract = {
          key = "audiobookshelf"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.ebooks]
}

resource "kubernetes_manifest" "servarr_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "servarr-secrets"
      namespace = "ebooks"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "servarr-secrets"
      }
      dataFrom = [{
        extract = {
          key = "servarr"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.ebooks]
}

# Data sources to read ExternalSecret-created secrets
data "kubernetes_secret" "calibre_secrets" {
  metadata {
    name      = "calibre-secrets"
    namespace = kubernetes_namespace.ebooks.metadata[0].name
  }
  depends_on = [kubernetes_manifest.calibre_external_secret]
}

data "kubernetes_secret" "audiobookshelf_secrets" {
  metadata {
    name      = "audiobookshelf-secrets"
    namespace = kubernetes_namespace.ebooks.metadata[0].name
  }
  depends_on = [kubernetes_manifest.audiobookshelf_external_secret]
}

data "kubernetes_secret" "servarr_secrets" {
  metadata {
    name      = "servarr-secrets"
    namespace = kubernetes_namespace.ebooks.metadata[0].name
  }
  depends_on = [kubernetes_manifest.servarr_external_secret]
}

locals {
  calibre_homepage_credentials        = jsondecode(data.kubernetes_secret.calibre_secrets.data["homepage_credentials"])
  audiobookshelf_homepage_credentials = jsondecode(data.kubernetes_secret.audiobookshelf_secrets.data["homepage_credentials"])
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.ebooks.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# NFS Volumes - Calibre (prefixed with ebooks- to avoid PV name clash with old stacks)
module "nfs_calibre_library_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "ebooks-calibre-library-host"
  namespace  = kubernetes_namespace.ebooks.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/calibre-web-automated/calibre-library"
}

# iSCSI volume for config (SQLite DBs) - enables WAL mode for concurrent reads/writes
resource "kubernetes_persistent_volume_claim" "calibre_config_iscsi" {
  metadata {
    name      = "ebooks-calibre-config-proxmox"
    namespace = kubernetes_namespace.ebooks.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
      "resize.topolvm.io/increase"      = "50%"
      "resize.topolvm.io/storage_limit" = "10Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = {
        storage = "2Gi"
      }
    }
  }
}

module "nfs_calibre_ingest_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "ebooks-calibre-ingest-host"
  namespace  = kubernetes_namespace.ebooks.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/calibre-web-automated/cwa-book-ingest"
}

module "nfs_calibre_stacks_config_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "ebooks-calibre-stacks-config-host"
  namespace  = kubernetes_namespace.ebooks.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/calibre-web-automated/stacks"
}

# NFS Volumes - Audiobookshelf (prefixed with ebooks- to avoid PV name clash)
module "nfs_audiobookshelf_audiobooks_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "ebooks-abs-audiobooks-host"
  namespace  = kubernetes_namespace.ebooks.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/audiobookshelf/audiobooks"
}

module "nfs_audiobookshelf_podcasts_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "ebooks-abs-podcasts-host"
  namespace  = kubernetes_namespace.ebooks.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/audiobookshelf/podcasts"
}

resource "kubernetes_persistent_volume_claim" "abs_config_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "ebooks-abs-config-proxmox"
    namespace = kubernetes_namespace.ebooks.metadata[0].name
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

module "nfs_audiobookshelf_metadata_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "ebooks-abs-metadata-host"
  namespace  = kubernetes_namespace.ebooks.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/audiobookshelf/metadata"
}

# Calibre-Web-Automated Deployment
resource "kubernetes_deployment" "calibre-web-automated" {
  wait_for_rollout = true
  metadata {
    name      = "calibre-web-automated"
    namespace = kubernetes_namespace.ebooks.metadata[0].name
    labels = {
      app  = "calibre-web-automated"
      tier = local.tiers.edge
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
        app = "calibre-web-automated"
      }
    }
    template {
      metadata {
        annotations = {
          "diun.enable"       = "false"
          "diun.include_tags" = "^\\d+(?:\\.\\d+)?(?:\\.\\d+)?$"
        }
        labels = {
          app = "calibre-web-automated"
        }
      }
      spec {
        container {
          image = "viktorbarzin/calibre-web-automated:latest"
          name  = "calibre-web-automated"
          env {
            name  = "PUID"
            value = 1000
          }
          env {
            name  = "PGID"
            value = 1000
          }
          env {
            name  = "NO_CHOWN"
            value = "true"
          }
          env {
            name  = "CALIBRE_PORT"
            value = "8083"
          }

          port {
            container_port = 8083
          }
          startup_probe {
            http_get {
              path = "/"
              port = 8083
            }
            initial_delay_seconds = 10
            timeout_seconds       = 5
            period_seconds        = 5
            failure_threshold     = 24
          }
          liveness_probe {
            http_get {
              path = "/"
              port = 8083
            }
            timeout_seconds   = 10
            period_seconds    = 30
            failure_threshold = 6
          }
          resources {
            requests = {
              cpu    = "50m"
              memory = "512Mi"
            }
            limits = {
              memory = "1Gi"
            }
          }
          volume_mount {
            name       = "config"
            mount_path = "/config"
          }
          volume_mount {
            name       = "library"
            mount_path = "/calibre-library"
          }
          volume_mount {
            name       = "ingest"
            mount_path = "/cwa-book-ingest"
          }
        }
        volume {
          name = "library"
          persistent_volume_claim {
            claim_name = module.nfs_calibre_library_host.claim_name
          }
        }
        volume {
          name = "config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.calibre_config_iscsi.metadata[0].name
          }
        }
        volume {
          name = "ingest"
          persistent_volume_claim {
            claim_name = module.nfs_calibre_ingest_host.claim_name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}

resource "kubernetes_service" "calibre" {
  metadata {
    name      = "calibre"
    namespace = kubernetes_namespace.ebooks.metadata[0].name
    labels = {
      "app" = "calibre"
    }
  }

  spec {
    selector = {
      app = "calibre-web-automated"
    }
    port {
      name        = "http"
      target_port = 8083
      port        = 80
      protocol    = "TCP"
    }
  }
}

module "calibre_ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.ebooks.metadata[0].name
  name            = "calibre"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"         = "true"
    "gethomepage.dev/description"     = "Book library"
    "gethomepage.dev/group"           = "Media & Entertainment"
    "gethomepage.dev/icon"            = "calibre-web.png"
    "gethomepage.dev/name"            = "Calibre"
    "gethomepage.dev/widget.type"     = "calibreweb"
    "gethomepage.dev/widget.url"      = "http://calibre.ebooks.svc.cluster.local"
    "gethomepage.dev/widget.username" = local.calibre_homepage_credentials["calibre-web"]["username"]
    "gethomepage.dev/widget.password" = local.calibre_homepage_credentials["calibre-web"]["password"]
    "gethomepage.dev/pod-selector"    = ""
  }
}

# Stacks - Anna's Archive Download Manager
resource "kubernetes_deployment" "annas-archive-stacks" {
  metadata {
    name      = "annas-archive-stacks"
    namespace = kubernetes_namespace.ebooks.metadata[0].name
    labels = {
      app  = "annas-archive-stacks"
      tier = local.tiers.edge
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "annas-archive-stacks"
      }
    }
    template {
      metadata {
        labels = {
          app = "annas-archive-stacks"
        }
      }
      spec {
        container {
          image = "zelest/stacks:latest"
          name  = "annas-archive-stacks"
          resources {
            requests = {
              cpu    = "10m"
              memory = "384Mi"
            }
            limits = {
              memory = "384Mi"
            }
          }
          port {
            container_port = 7788
          }
          liveness_probe {
            http_get {
              path = "/api/version"
              port = 7788
            }
            initial_delay_seconds = 15
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 3
          }
          volume_mount {
            name       = "config"
            mount_path = "/opt/stacks/config"
          }
          volume_mount {
            name       = "ingest"
            mount_path = "/opt/stacks/download"
          }
        }
        volume {
          name = "config"
          persistent_volume_claim {
            claim_name = module.nfs_calibre_stacks_config_host.claim_name
          }
        }
        volume {
          name = "ingest"
          persistent_volume_claim {
            claim_name = module.nfs_calibre_ingest_host.claim_name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}

resource "kubernetes_service" "annas-archive-stacks" {
  metadata {
    name      = "annas-archive-stacks"
    namespace = kubernetes_namespace.ebooks.metadata[0].name
    labels = {
      "app" = "annas-archive-stacks"
    }
  }

  spec {
    selector = {
      app = "annas-archive-stacks"
    }
    port {
      name        = "http"
      port        = "80"
      target_port = 7788
    }
  }
}

module "stacks_ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.ebooks.metadata[0].name
  name            = "stacks"
  service_name    = "annas-archive-stacks"
  tls_secret_name = var.tls_secret_name
  protected       = true
  extra_annotations = {
    "gethomepage.dev/enabled" = "false"
  }
}

# Audiobookshelf Deployment
resource "kubernetes_deployment" "audiobookshelf" {
  metadata {
    name      = "audiobookshelf"
    namespace = kubernetes_namespace.ebooks.metadata[0].name
    labels = {
      app  = "audiobookshelf"
      tier = local.tiers.edge
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
          image = "ghcr.io/advplyr/audiobookshelf:2.33.1"
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
              memory = "256Mi"
            }
          }
        }
        volume {
          name = "audiobooks"
          persistent_volume_claim {
            claim_name = module.nfs_audiobookshelf_audiobooks_host.claim_name
          }
        }
        volume {
          name = "podcasts"
          persistent_volume_claim {
            claim_name = module.nfs_audiobookshelf_podcasts_host.claim_name
          }
        }
        volume {
          name = "config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.abs_config_proxmox.metadata[0].name
          }
        }
        volume {
          name = "metadata"
          persistent_volume_claim {
            claim_name = module.nfs_audiobookshelf_metadata_host.claim_name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}

resource "kubernetes_service" "audiobookshelf" {
  metadata {
    name      = "audiobookshelf"
    namespace = kubernetes_namespace.ebooks.metadata[0].name
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

module "audiobookshelf_ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "non-proxied"
  namespace       = kubernetes_namespace.ebooks.metadata[0].name
  name            = "audiobookshelf"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Audiobookshelf"
    "gethomepage.dev/description"  = "Audiobook library"
    "gethomepage.dev/icon"         = "audiobookshelf.png"
    "gethomepage.dev/group"        = "Media & Entertainment"
    "gethomepage.dev/pod-selector" = ""
    "gethomepage.dev/widget.type"  = "audiobookshelf"
    "gethomepage.dev/widget.url"   = "http://audiobookshelf.ebooks.svc.cluster.local"
    "gethomepage.dev/widget.key"   = local.audiobookshelf_homepage_credentials["audiobookshelf"]["token"]
  }
}

# Book-Search Deployment
resource "kubernetes_deployment" "book_search" {
  metadata {
    name      = "book-search"
    namespace = kubernetes_namespace.ebooks.metadata[0].name
    labels = {
      app  = "book-search"
      tier = local.tiers.edge
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "book-search"
      }
    }
    template {
      metadata {
        labels = {
          app = "book-search"
        }
      }
      spec {
        container {
          image             = "viktorbarzin/book-search:latest"
          image_pull_policy = "Always"
          name              = "book-search"

          port {
            container_port = 8000
          }
          env {
            name  = "QBITTORRENT_URL"
            value = "http://qbittorrent.servarr.svc.cluster.local"
          }
          env {
            name = "QBITTORRENT_PASS"
            value_from {
              secret_key_ref {
                name = "servarr-secrets"
                key  = "qbittorrent_password"
              }
            }
          }
          env {
            name  = "AUDIOBOOKSHELF_URL"
            value = "http://audiobookshelf.ebooks.svc.cluster.local"
          }
          env {
            name = "AUDIOBOOKSHELF_TOKEN"
            value_from {
              secret_key_ref {
                name = "servarr-secrets"
                key  = "audiobookshelf_api_token"
              }
            }
          }
          env {
            name = "MAM_EMAIL"
            value_from {
              secret_key_ref {
                name = "servarr-secrets"
                key  = "mam_email"
              }
            }
          }
          env {
            name = "MAM_PASSWORD"
            value_from {
              secret_key_ref {
                name = "servarr-secrets"
                key  = "mam_password"
              }
            }
          }
          env {
            name  = "CWA_INGEST_PATH"
            value = "/cwa-book-ingest"
          }
          env {
            name = "MAM_ID"
            value_from {
              secret_key_ref {
                name     = "servarr-secrets"
                key      = "mam_id"
                optional = true
              }
            }
          }
          env {
            name = "API_KEY"
            value_from {
              secret_key_ref {
                name = "calibre-secrets"
                key  = "book_search_api_key"
              }
            }
          }
          env {
            name  = "SHORTCUT_ICLOUD_URL"
            value = ""
          }
          env {
            name  = "STACKS_DB_PATH"
            value = "/stacks-config/queue.db"
          }
          env {
            name  = "CALIBRE_WEB_USER"
            value = "admin"
          }
          env {
            name = "CALIBRE_WEB_PASS"
            value_from {
              secret_key_ref {
                name = "calibre-secrets"
                key  = "calibre_web_password"
              }
            }
          }
          env {
            name  = "SMTP_HOST"
            value = "mail.viktorbarzin.me"
          }
          env {
            name  = "SMTP_PORT"
            value = "587"
          }
          env {
            name  = "SMTP_USER"
            value = "calibre-web@viktorbarzin.me"
          }
          env {
            name  = "SMTP_FROM"
            value = "Calibre-Web <calibre-web@viktorbarzin.me>"
          }
          env {
            name = "SMTP_PASS"
            value_from {
              secret_key_ref {
                name = "calibre-secrets"
                key  = "smtp_password"
              }
            }
          }
          env {
            name = "SLACK_WEBHOOK_URL"
            value_from {
              secret_key_ref {
                name = "calibre-secrets"
                key  = "slack_webhook_url"
              }
            }
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "128Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
          liveness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            initial_delay_seconds = 10
            period_seconds        = 30
          }
          volume_mount {
            name       = "cwa-ingest"
            mount_path = "/cwa-book-ingest"
          }
          volume_mount {
            name       = "audiobooks"
            mount_path = "/audiobooks"
          }
          volume_mount {
            name       = "stacks-config"
            mount_path = "/stacks-config"
          }
          volume_mount {
            name       = "calibre-library"
            mount_path = "/calibre-library"
          }
        }
        volume {
          name = "cwa-ingest"
          persistent_volume_claim {
            claim_name = module.nfs_calibre_ingest_host.claim_name
          }
        }
        volume {
          name = "audiobooks"
          persistent_volume_claim {
            claim_name = module.nfs_audiobookshelf_audiobooks_host.claim_name
          }
        }
        volume {
          name = "calibre-library"
          persistent_volume_claim {
            claim_name = module.nfs_calibre_library_host.claim_name
          }
        }
        volume {
          name = "stacks-config"
          persistent_volume_claim {
            claim_name = module.nfs_calibre_stacks_config_host.claim_name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}

resource "kubernetes_service" "book_search" {
  metadata {
    name      = "book-search"
    namespace = kubernetes_namespace.ebooks.metadata[0].name
    labels = {
      app = "book-search"
    }
  }

  spec {
    selector = {
      app = "book-search"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8000
    }
  }
}

module "book_search_ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.ebooks.metadata[0].name
  name            = "book-search"
  tls_secret_name = var.tls_secret_name
  protected       = true
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Book Search"
    "gethomepage.dev/description"  = "Search & download books"
    "gethomepage.dev/icon"         = "audiobookshelf.png"
    "gethomepage.dev/group"        = "Media & Entertainment"
    "gethomepage.dev/pod-selector" = ""
  }
}

# API ingress - unprotected (API key auth handled by backend)
module "book_search_api_ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.ebooks.metadata[0].name
  name            = "book-search-api"
  host            = "book-search"
  service_name    = "book-search"
  tls_secret_name = var.tls_secret_name
  protected       = false
  ingress_path    = ["/api/download-url", "/api/download-status", "/api/send-to-kindle", "/shortcut"]
}
