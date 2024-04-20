variable "tls_secret_name" {}
variable "valchedrym_camera_credentials" {
  // in the format:
  // username:password
  default = ""
}

resource "kubernetes_namespace" "frigate" {
  metadata {
    name = "frigate"
    # labels = {
    #   "istio-injection" : "enabled"
    # }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "frigate"
  tls_secret_name = var.tls_secret_name
}

## Disabled as config is now in data volume
#
# resource "kubernetes_config_map" "config" {
#   metadata {
#     name      = "config"
#     namespace = "frigate"

#     labels = {
#       app = "frigate"
#     }
#     annotations = {
#       "reloader.stakater.com/match" = "true"
#     }
#   }

#   data = {
#     # Actual mail settings
#     "config.yml" = <<-EOT
#     mqtt:
#         enabled: False
#     cameras:
#         # Temp disabled until valchedrym is back up
#         valchedrym-cam-1: 
#            enabled: true
#            ffmpeg:
#                inputs:
#                    #- path: rtsp://${var.valchedrym_camera_credentials}@192.168.0.11:554/Streaming/Channels/101 # <----- The stream you want to use for detection
#                    - path: rtsp://${var.valchedrym_camera_credentials}@valchedrym.ddns.net:554/Streaming/Channels/101 # <----- The stream you want to use for detection
#            detect:
#                enabled: True # <---- disable detection until you have a working camera feed
#                width: 704 # <---- update for your camera's resolution
#                height: 576 # <---- update for your camera's resolution
#            objects:
#              # Optional: list of objects to track from labelmap.txt (full list - https://docs.frigate.video/configuration/objects)
#              track:
#                - person
#                - bicycle
#                - car
#                - bird
#                - cat
#                - dog
#                - horse
#         valchedrym-cam-2: 
#            enabled: true
#            ffmpeg:
#                inputs:
#                    #- path: rtsp://${var.valchedrym_camera_credentials}@192.168.0.11:554/Streaming/Channels/201 # <----- The stream you want to use for detection
#                    - path: rtsp://${var.valchedrym_camera_credentials}@valchedrym.ddns.net:554/Streaming/Channels/201 # <----- The stream you want to use for detection
#            detect:
#                enabled: True # <---- disable detection until you have a working camera feed
#                width: 704 # <---- update for your camera's resolution
#                height: 576 # <---- update for your camera's resolution
#            objects:
#              # Optional: list of objects to track from labelmap.txt (full list - https://docs.frigate.video/configuration/objects)
#              track:
#                - person
#                - bicycle
#                - car
#                - bird
#                - cat
#                - dog
#                - horse
#         london-ipcam:
#             enabled: false
#             ffmpeg:
#                 inputs:
#                     - path: rtsp://192.168.2.2:8554/london_cam # <----- The stream you want to use for detection
#                       roles:
#                         - rtmp
#                         - record
#                         - detect
#             detect:
#                 enabled: False
#                 width: 1280
#                 height: 720
#             record:
#                 enabled: False # Not needed for this camera but keeping for reference
#                 events:
#                   retain:
#                     default: 10
#             objects:
#               # Optional: list of objects to track from labelmap.txt (full list - https://docs.frigate.video/configuration/objects)
#               track:
#                 - person
#                 - shoe
#                 - handbag
#                 - wine glass
#                 - knife
#                 - pizza
#                 - laptop
#                 - book
#     EOT
#   }
#   # Password hashes are different each time and avoid changing secret constantly. 
#   # Either 1.Create consistent hashes or 2.Find a way to ignore_changes on per password
#   lifecycle {
#     ignore_changes = [data["postfix-accounts.cf"]]
#   }
# }

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
    replicas = 0 # Temporarily disabled due to high power consumption
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
            mount_path = "/config"
            # mount_path = "/config/config.yml"
            # sub_path   = "config.yml"
          }
          volume_mount {
            name       = "media"
            mount_path = "/media/frigate"
          }
          volume_mount {
            name       = "dshm"
            mount_path = "/dev/shm"
          }
        }
        volume {
          name = "config"
          # config_map {
          #   name = "config"
          # }
          nfs {
            path   = "/mnt/main/frigate"
            server = "10.0.10.15"
          }
        }
        volume {
          name = "dshm"
          empty_dir {
            medium     = "Memory"
            size_limit = "1Gi"
          }
        }
        volume {
          name = "media"
          nfs {
            path   = "/mnt/main/frigate"
            server = "10.0.10.15"
          }
        }
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

