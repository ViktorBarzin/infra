variable "frame_api_key" {
  type = string
}

resource "kubernetes_config_map" "mailserver_config" {
  metadata {
    name      = "config"
    namespace = "immich"

    labels = {
      app = "frame-config"
    }
    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }

  data = {
    # Actual mail settings
    "Settings.yml" = <<-EOF
    General:
        Layout: single
        Interval: 10
        ImageZoom: false
        ShowAlbumName: false
        ShowProgressBar: false
    Accounts:
        - ImmichServerUrl: http://immich.viktorbarzin.me
          ApiKey: ${var.frame_api_key}
          Albums: 
            - 1aa98849-bbd5-452b-aac0-310b210a8597 # china
    EOF
  }
}


resource "kubernetes_deployment" "immich-frame" {
  metadata {
    name      = "immich-frame"
    namespace = "immich"
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
    labels = {
      tier = var.tier
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "immich-frame"
      }
    }
    strategy {
      type = "RollingUpdate"
    }
    template {
      metadata {
        labels = {
          app = "immich-frame"
        }
      }
      spec {
        container {
          image = "ghcr.io/immichframe/immichframe:latest"
          name  = "immich-frame"
          port {
            container_port = 8080
            protocol       = "TCP"
            name           = "http"
          }
          volume_mount {
            name       = "config"
            mount_path = "/app/Config"
            read_only  = true
          }
        }
        volume {
          name = "config"
          config_map {
            name = "config"
          }
        }
      }
    }
  }
}


resource "kubernetes_service" "immich-frame" {
  metadata {
    name      = "immich-frame"
    namespace = "immich"
    labels = {
      "app" = "immich-frame"
    }
  }

  spec {
    selector = {
      app = "immich-frame"
    }
    port {
      port        = 80
      target_port = 8080
    }
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = "immich"
  name            = "highlights-immich"
  tls_secret_name = var.tls_secret_name
  service_name    = "immich-frame"
  rybbit_site_id  = "602167601c6b"
}
