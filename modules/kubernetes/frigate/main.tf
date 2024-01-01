variable "tls_secret_name" {}

resource "kubernetes_namespace" "frigate" {
  metadata {
    name = "frigate"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "frigate"
  tls_secret_name = var.tls_secret_name
}
resource "kubernetes_config_map" "config" {
  metadata {
    name      = "config"
    namespace = "frigate"

    labels = {
      app = "frigate"
    }
    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }

  data = {
    # Actual mail settings
    "config.yml" = <<-EOT
    mqtt:
        enabled: False
    cameras:
        valchedrym-cam-1: 
            ffmpeg:
                inputs:
                    - path: rtsp://admin:R7CjHKNAzSPztinF@192.168.0.11:554/Streaming/Channels/101 # <----- The stream you want to use for detection
            detect:
                enabled: False # <---- disable detection until you have a working camera feed
                width: 704 # <---- update for your camera's resolution
                height: 576 # <---- update for your camera's resolution
        valchedrym-cam-2: 
            ffmpeg:
                inputs:
                    - path: rtsp://admin:R7CjHKNAzSPztinF@192.168.0.11:554/Streaming/Channels/201 # <----- The stream you want to use for detection
            detect:
                enabled: False # <---- disable detection until you have a working camera feed
                width: 704 # <---- update for your camera's resolution
                height: 576 # <---- update for your camera's resolution
    EOT
  }
  # Password hashes are different each time and avoid changing secret constantly. 
  # Either 1.Create consistent hashes or 2.Find a way to ignore_changes on per password
  lifecycle {
    ignore_changes = [data["postfix-accounts.cf"]]
  }
}

resource "kubernetes_deployment" "frigate" {
  metadata {
    name      = "frigate"
    namespace = "frigate"
    labels = {
      app = "frigate"
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
        app = "frigate"
      }
    }
    template {
      metadata {
        labels = {
          app = "frigate"
        }
      }
      spec {
        container {
          image = "ghcr.io/blakeblackshear/frigate:stable"
          name  = "frigate"
          env {
            name  = "FRIGATE_RTSP_PASSWORD"
            value = "password"
          }

          port {
            container_port = 5000
          }
          port {
            container_port = 8554
          }
          port {
            container_port = 8555
            protocol       = "TCP"
          }
          port {
            container_port = 8555
            protocol       = "UDP"
          }
          volume_mount {
            name       = "config"
            mount_path = "/config/config.yml"
            sub_path   = "config.yml"
          }
        }
        volume {
          name = "config"
          config_map {
            name = "config"
          }
        }
        # volume {
        #   name = "audiobooks"
        #   nfs {
        #     path   = "/mnt/main/frigate/audiobooks"
        #     server = "10.0.10.15"
        #   }
        # }
      }
    }
  }
}

resource "kubernetes_service" "frigate" {
  metadata {
    name      = "frigate"
    namespace = "frigate"
    labels = {
      "app" = "frigate"
    }
  }

  spec {
    selector = {
      app = "frigate"
    }
    port {
      name        = "http"
      target_port = 5000
      port        = 80
      protocol    = "TCP"
    }
  }
}

resource "kubernetes_ingress_v1" "frigate" {
  metadata {
    name      = "frigate"
    namespace = "frigate"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
      "nginx.ingress.kubernetes.io/proxy-body-size" : "20000m"
      "nginx.ingress.kubernetes.io/auth-url" : "https://oauth2.viktorbarzin.me/oauth2/auth"
      "nginx.ingress.kubernetes.io/auth-signin" : "https://oauth2.viktorbarzin.me/oauth2/start?rd=/redirect/$http_host$escaped_request_uri"
    }
  }

  spec {
    tls {
      hosts       = ["frigate.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "frigate.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "frigate"
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

