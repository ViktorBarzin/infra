# =============================================================================
# library — stremio-library.viktorbarzin.me, the "Our server" Stremio addon
# =============================================================================
# Plays films and episodes that qBittorrent downloaded to our NFS share, for
# releases Real-Debrid refuses (its May 2026 filter on names like WEB-DL) or
# does not have. Added 2026-11-23 for Undercover season 6, which exists only as
# BULTOR WEB-DL releases.
#
# Files: qBittorrent category "stremio" saves to /downloads/stremio/<imdb id>/
# (NFS /srv/nfs/servarr/downloads/stremio); this pod mounts that folder
# read-only. files/library.py lists the finished video files as stream rows and
# serves them with byte ranges. Install URL (shared Stremio account):
# https://stremio-library.viktorbarzin.me/<token>/manifest.json; the token is
# in Secret stremio/library.

resource "random_id" "library_token" {
  byte_length = 24
}

resource "kubernetes_secret" "library" {
  metadata {
    name      = "library"
    namespace = kubernetes_namespace.stremio.metadata[0].name
  }
  data = {
    LIBRARY_TOKEN = random_id.library_token.hex
  }
}

resource "kubernetes_config_map" "library" {
  metadata {
    name      = "library"
    namespace = kubernetes_namespace.stremio.metadata[0].name
  }
  data = {
    "library.py" = file("${path.module}/files/library.py")
  }
}

module "nfs_library" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "stremio-library-downloads"
  namespace          = kubernetes_namespace.stremio.metadata[0].name
  nfs_server         = "192.168.1.127"
  nfs_path           = "/srv/nfs/servarr/downloads"
  storage_class_name = "nfs-pve"
}

resource "kubernetes_deployment" "library" {
  metadata {
    name      = "library"
    namespace = kubernetes_namespace.stremio.metadata[0].name
    labels    = { app = "stremio-library", tier = local.tiers.gpu }
  }
  spec {
    replicas = 1
    selector { match_labels = { app = "stremio-library" } }
    template {
      metadata {
        labels      = { app = "stremio-library" }
        annotations = { "checksum/code" = sha256(file("${path.module}/files/library.py")) }
      }
      spec {
        security_context {
          run_as_user     = 65534
          run_as_group    = 65534
          run_as_non_root = true
        }
        container {
          name    = "library"
          image   = "docker.io/library/python:3.15.2-alpine"
          command = ["python3", "-u", "/app/library.py"]
          env {
            name  = "LIBRARY_DIR"
            value = "/media"
          }
          env {
            name  = "PUBLIC_URL"
            value = "https://stremio-library.viktorbarzin.me"
          }
          env {
            name = "LIBRARY_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.library.metadata[0].name
                key  = "LIBRARY_TOKEN"
              }
            }
          }
          port {
            container_port = 8080
            name           = "http"
          }
          volume_mount {
            name       = "code"
            mount_path = "/app"
            read_only  = true
          }
          volume_mount {
            name       = "downloads"
            mount_path = "/media"
            sub_path   = "stremio"
            read_only  = true
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            period_seconds = 10
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 10
            period_seconds        = 30
          }
          resources {
            # Python stdlib server; each stream is a thread copying 1 MiB chunks.
            requests = {
              cpu    = "20m"
              memory = "48Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }
        volume {
          name = "code"
          config_map {
            name = kubernetes_config_map.library.metadata[0].name
          }
        }
        volume {
          name = "downloads"
          persistent_volume_claim {
            claim_name = module.nfs_library.claim_name
            read_only  = true
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "library" {
  metadata {
    name      = "library"
    namespace = kubernetes_namespace.stremio.metadata[0].name
    labels    = { app = "stremio-library" }
  }
  spec {
    selector = { app = "stremio-library" }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }
}

module "library_ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": the random token in every path is the gate (files/library.py
  # answers 404 without it), as for AIOStreams' install URLs. Stremio players
  # fetch the manifest, rows and video directly and cannot follow Authentik.
  auth             = "none"
  anti_ai_scraping = false # an addon API and video files; no pages to protect
  # Non-proxied: Cloudflare's terms bar serving video through its CDN (as for
  # stremio.viktorbarzin.me).
  dns_type        = "non-proxied"
  namespace       = kubernetes_namespace.stremio.metadata[0].name
  name            = "stremio-library"
  homepage_group  = "Media & Entertainment"
  service_name    = kubernetes_service.library.metadata[0].name
  tls_secret_name = var.tls_secret_name
  # No Turnstile gate: Stremio addon API, machine-only (docs/plans/2026-10-16-turnstile-sitewide-design.md).
  turnstile = false
  extra_annotations = {
    "gethomepage.dev/description" = "Stremio addon for films and episodes downloaded to our server"
  }
}
