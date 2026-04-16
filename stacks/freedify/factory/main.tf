variable "tls_secret_name" {}
variable "name" {}
variable "tag" {
  default = "latest"
}
variable "tier" { type = string }
variable "protected" {
  type    = bool
  default = false
}
variable "listenbrainz_token" {
  type      = string
  default   = null
  sensitive = true
}
variable "genius_token" {
  type      = string
  default   = null
  sensitive = true
}
variable "dab_visitor_id" {
  type    = string
  default = null
}
variable "dab_session" {
  type    = string
  default = null
}
variable "gemini_api_key" {
  type      = string
  default   = null
  sensitive = true
}
variable "memory_limit" {
  type    = string
  default = "384Mi"
}
variable "cpu_request" {
  type    = string
  default = "15m"
}
variable "memory_request" {
  type    = string
  default = "256Mi"
}
variable "extra_annotations" {
  type    = map(string)
  default = {}
}
variable "navidrome_scan_url" {
  type      = string
  default   = ""
  sensitive = true
}
variable "ha_sofia_url" {
  type    = string
  default = ""
}
variable "ha_sofia_token" {
  type      = string
  default   = ""
  sensitive = true
}
variable "nfs_music_server" {
  type    = string
  default = "192.168.1.127"
}
variable "nfs_music_path" {
  type    = string
  default = "/srv/nfs/freedify-music"
}


resource "kubernetes_deployment" "freedify" {
  metadata {
    name      = "music-${var.name}"
    namespace = "freedify"
    labels = {
      app  = "music-${var.name}"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "RollingUpdate"
    }
    selector {
      match_labels = {
        app = "music-${var.name}"
      }
    }
    template {
      metadata {
        annotations = {
          "diun.enable"       = "true"
          "diun.include_tags" = "^${var.tag}$"
        }
        labels = {
          app = "music-${var.name}"
        }
      }
      spec {
        image_pull_secrets {
          name = "registry-credentials"
        }
        container {
          image = "registry.viktorbarzin.me/freedify:${var.tag}"
          name  = "freedify"

          # Patch: fix Safari iOS playback (AirPlay needs source-level fix)
          # 1. Remove EQ auto-init on play events (audio-engine.js)
          # 2. Remove iOS keepalive AudioContext creation (dom.js)
          # 3. Remove visualizer's initEqualizer() call (dj.js)
          command = ["sh", "-c"]
          args = [
            "sed -i '/addEventListener.*play.*handleEQResume/d' /app/static/audio-engine.js && sed -i '/iosAudioContext = new /d' /app/static/dom.js && sed -i '/initEqualizer()/d' /app/static/dj.js && exec python -m uvicorn app.main:app --host 0.0.0.0 --port $${PORT:-8000} --timeout-keep-alive 120"
          ]

          port {
            container_port = 8000
          }
          env {
            name  = "LISTENBRAINZ_TOKEN"
            value = var.listenbrainz_token
          }
          env {
            name  = "GENIUS_ACCESS_TOKEN"
            value = var.genius_token
          }
          env {
            name  = "DAB_SESSION"
            value = var.dab_session
          }
          env {
            name  = "DAB_VISITOR_ID"
            value = var.dab_visitor_id
          }
          env {
            name  = "GEMINI_API_KEY"
            value = var.gemini_api_key
          }
          env {
            name  = "MUSIC_LIBRARY_PATH"
            value = "/music-library"
          }
          env {
            name  = "AUTO_SAVE_TO_LIBRARY"
            value = "true"
          }
          env {
            name  = "NAVIDROME_SCAN_URL"
            value = var.navidrome_scan_url
          }
          env {
            name  = "HA_SOFIA_URL"
            value = var.ha_sofia_url
          }
          env {
            name  = "HA_SOFIA_TOKEN"
            value = var.ha_sofia_token
          }
          volume_mount {
            name       = "music-library"
            mount_path = "/music-library"
          }
          resources {
            limits = {
              memory = var.memory_limit
            }
            requests = {
              cpu    = var.cpu_request
              memory = var.memory_request
            }
          }
          readiness_probe {
            http_get {
              path = "/"
              port = 8000
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
          liveness_probe {
            http_get {
              path = "/"
              port = 8000
            }
            initial_delay_seconds = 10
            period_seconds        = 30
            failure_threshold     = 3
          }
        }
        volume {
          name = "music-library"
          nfs {
            server = var.nfs_music_server
            path   = var.nfs_music_path
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}

resource "kubernetes_service" "freedify" {
  metadata {
    name      = "music-${var.name}"
    namespace = "freedify"
    labels = {
      app = "music-${var.name}"
    }
  }

  spec {
    selector = {
      app = "music-${var.name}"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8000
    }
  }
}

module "ingress" {
  source            = "../../../modules/kubernetes/ingress_factory"
  namespace         = "freedify"
  name              = "music-${var.name}"
  tls_secret_name   = var.tls_secret_name
  dns_type          = "non-proxied"
  protected         = var.protected
  extra_annotations = var.extra_annotations
}

# Unauthenticated ingress for /api/stream/ — allows AirPlay receivers to fetch audio directly
resource "kubernetes_ingress_v1" "stream-noauth" {
  metadata {
    name      = "music-${var.name}-stream"
    namespace = "freedify"
    annotations = {
      "traefik.ingress.kubernetes.io/router.middlewares"  = "traefik-retry@kubernetescrd,traefik-rate-limit@kubernetescrd"
      "traefik.ingress.kubernetes.io/router.entrypoints"  = "websecure"
      "traefik.ingress.kubernetes.io/router.priority"     = "100"
    }
  }
  spec {
    ingress_class_name = "traefik"
    tls {
      hosts       = ["music-${var.name}.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "music-${var.name}.viktorbarzin.me"
      http {
        path {
          path      = "/api/stream/"
          path_type = "Prefix"
          backend {
            service {
              name = "music-${var.name}"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}
