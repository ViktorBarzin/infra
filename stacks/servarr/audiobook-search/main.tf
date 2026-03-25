variable "tls_secret_name" {}
variable "tier" { type = string }
variable "audiobookshelf_token" {
  type      = string
  sensitive = true
}
variable "qbittorrent_password" {
  type      = string
  sensitive = true
}
variable "mam_email" {
  type      = string
  sensitive = true
  default   = ""
}
variable "mam_password" {
  type      = string
  sensitive = true
  default   = ""
}

resource "kubernetes_deployment" "audiobook_search" {
  metadata {
    name      = "audiobook-search"
    namespace = "servarr"
    labels = {
      app  = "audiobook-search"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "audiobook-search"
      }
    }
    template {
      metadata {
        labels = {
          app = "audiobook-search"
        }
      }
      spec {
        container {
          image             = "viktorbarzin/audiobook-search:latest"
          image_pull_policy = "Always"
          name  = "audiobook-search"

          port {
            container_port = 8000
          }
          env {
            name  = "QBITTORRENT_URL"
            value = "http://qbittorrent.servarr.svc.cluster.local"
          }
          env {
            name  = "QBITTORRENT_PASS"
            value = var.qbittorrent_password
          }
          env {
            name  = "AUDIOBOOKSHELF_URL"
            value = "http://audiobookshelf.audiobookshelf.svc.cluster.local"
          }
          env {
            name  = "AUDIOBOOKSHELF_TOKEN"
            value = var.audiobookshelf_token
          }
          env {
            name  = "MAM_EMAIL"
            value = var.mam_email
          }
          env {
            name  = "MAM_PASSWORD"
            value = var.mam_password
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "128Mi"
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
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}

resource "kubernetes_service" "audiobook_search" {
  metadata {
    name      = "audiobook-search"
    namespace = "servarr"
    labels = {
      app = "audiobook-search"
    }
  }

  spec {
    selector = {
      app = "audiobook-search"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8000
    }
  }
}

module "ingress" {
  source          = "../../../modules/kubernetes/ingress_factory"
  namespace       = "servarr"
  name            = "audiobook-search"
  tls_secret_name = var.tls_secret_name
  protected       = true
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Audiobook Search"
    "gethomepage.dev/description"  = "Search & download audiobooks"
    "gethomepage.dev/icon"         = "audiobookshelf.png"
    "gethomepage.dev/group"        = "Media & Entertainment"
    "gethomepage.dev/pod-selector" = ""
  }
}
