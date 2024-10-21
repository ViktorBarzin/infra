variable "tls_secret_name" {}
variable "postgresql_password" {}
variable "homepage_token" {}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "immich"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_namespace" "immich" {
  metadata {
    name = "immich"
    # Container comms are broken - seems due to tls
    # labels = {
    #   "istio-injection" : "enabled"
    # }
  }
}

resource "kubernetes_persistent_volume" "immich-postgresql" {
  metadata {
    name = "immich-postgresql"
  }
  spec {
    capacity = {
      "storage" = "10Gi"
    }
    access_modes = ["ReadWriteOnce"]
    persistent_volume_source {
      nfs {
        path   = "/mnt/main/immich/data-immich-postgresql"
        server = "10.0.10.15"
      }
    }
  }
}

resource "kubernetes_persistent_volume" "immich" {
  metadata {
    name = "immich"
  }
  spec {
    capacity = {
      "storage" = "100Gi"
    }
    access_modes = ["ReadWriteOnce"]
    persistent_volume_source {
      nfs {
        path   = "/mnt/main/immich/immich"
        server = "10.0.10.15"
      }
    }
  }
}

resource "kubernetes_persistent_volume" "immich-typesense-tsdata" {
  metadata {
    name = "immich-typesense-tsdata"
  }
  spec {
    capacity = {
      "storage" = "5Gi"
    }
    access_modes = ["ReadWriteOnce"]
    persistent_volume_source {
      nfs {
        path   = "/mnt/main/immich/typesense-tsdata"
        server = "10.0.10.15"
      }
    }
  }
}
resource "kubernetes_persistent_volume_claim" "immich" {
  metadata {
    name      = "immich"
    namespace = "immich"
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        "storage" = "20Gi"
      }
    }
    volume_name = "immich"
  }
}

# If you're having issuewith typesens container exiting prematurely, increase liveliness check
resource "helm_release" "immich" {
  namespace = "immich"
  name      = "immich"

  repository = "https://immich-app.github.io/immich-charts"
  chart      = "immich"
  atomic     = true
  version    = "0.8.1"
  # version = "0.7.2"
  timeout = 6000

  values = [templatefile("${path.module}/chart_values.tpl", { postgresql_password = var.postgresql_password })]
}

resource "kubernetes_ingress_v1" "immich" {
  metadata {
    name      = "immich"
    namespace = "immich"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
      # "nginx.ingress.kubernetes.io/auth-url" : "https://oauth2.viktorbarzin.me/oauth2/auth"
      # "nginx.ingress.kubernetes.io/auth-signin" : "https://oauth2.viktorbarzin.me/oauth2/start?rd=/redirect/$http_host$escaped_request_uri"

      # WARNING: When changing any of the below settings, ensure that large file uploads continue working
      "nginx.ingress.kubernetes.io/proxy-read-timeout" : "6000",
      "nginx.ingress.kubernetes.io/proxy-send-timeout" : "6000",
      "nginx.ingress.kubernetes.io/proxy-connect-timeout" : "6000"
      "nginx.ingress.kubernetes.io/client-max-body-size" : "0"
      # "nginx.ingress.kubernetes.io/proxy-body-size" : "5G",
      "nginx.ingress.kubernetes.io/proxy-body-size" : "0",
      # "nginx.ingress.kubernetes.io/proxy-buffering" : "on"
      # "nginx.ingress.kubernetes.io/proxy-max-temp-file-size" : "4096m"
      # "nginx.ingress.kubernetes.io/proxy-request-buffering" : "off"
      # "nginx.ingress.kubernetes.io/client-body-buffer-size" : "5G"
      # "nginx.ingress.kubernetes.io/proxy-buffer-size" : "16k"
      # "nginx.ingress.kubernetes.io/proxy-buffers-number" : "8"


      # "nginx.ingress.kubernetes.io/client-body-buffer-size" : "5000m"
      # "nginx.ingress.kubernetes.io/proxy-buffers-number" : "8"
      # "nginx.ingress.kubernetes.io/proxy-buffer-size" : "16k"
      # "nginx.ingress.kubernetes.io/proxy-body-size" : "0",
      # "nginx.ingress.kubernetes.io/affinity" : "cookie"
      # "nginx.ingress.kubernetes.io/affinity-mode" : "persistent"
      # "nginx.ingress.kubernetes.io/session-cookie-change-on-failure" : true
      # "nginx.ingress.kubernetes.io/session-cookie-expires" : 172800
      # "nginx.ingress.kubernetes.io/session-cookie-max-age" : 172800
      # "nginx.ingress.kubernetes.io/session-cookie-name" : "STICKY_SESSION"
      # "nginx.ingress.kubernetes.io/use-regex" : false
      "nginx.org/websocket-services" : "immich-server"

      "gethomepage.dev/enabled"      = "true"
      "gethomepage.dev/description"  = "Photos library"
      "gethomepage.dev/icon"         = "immich.png"
      "gethomepage.dev/name"         = "Immich"
      "gethomepage.dev/widget.type"  = "immich"
      "gethomepage.dev/widget.url"   = "https://immich.viktorbarzin.me"
      "gethomepage.dev/pod-selector" = ""
      "gethomepage.dev/widget.key"   = var.homepage_token

      # location ~* \.(png|jpg|jpeg|gif|webp|svg)$ {
      #   expires 1M;
      #   add_header Cache-Control "public, max-age=31536000, immutable";
      # }
      "nginx.ingress.kubernetes.io/configuration-snippet" = <<-EOF
        proxy_cache static-cache;
        proxy_cache_valid 404 1m;
        proxy_cache_use_stale error timeout updating http_404 http_500 http_502 http_503 http_504;
        proxy_cache_bypass $http_x_purge;
        add_header X-Cache-Status $upstream_cache_status;
        EOF
    }
  }

  spec {
    tls {
      hosts       = ["immich.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "immich.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              # name = "immich-proxy"
              name = "immich-server" # after v1.88
              port {
                # number = 8080
                number = 3001
                # number = 2283
              }
            }
          }
        }
      }
    }
  }
}
resource "kubernetes_ingress_v1" "photos" {
  metadata {
    name      = "photos"
    namespace = "immich"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
      "nginx.ingress.kubernetes.io/proxy-body-size" : "5000m"
    }
  }

  spec {
    tls {
      hosts       = ["photos.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "photos.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              # name = "immich-proxy"
              name = "immich-server" # after v1.88
              port {
                # number = 8080
                number = 3001
              }
            }
          }
        }
      }
    }
  }
}
