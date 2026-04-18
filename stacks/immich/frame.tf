
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
          ApiKey: ${data.vault_kv_secret_v2.secrets.data["frame_api_key"]}
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
      tier = local.tiers.gpu
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
        annotations = {
          "dependency.kyverno.io/wait-for" = "immich-server.immich:2283"
        }
      }
      spec {
        container {
          image = "ghcr.io/immichframe/immichframe:v1.0.32.0"
          name  = "immich-frame"
          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
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
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
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
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = "immich"
  name            = "highlights-immich"
  tls_secret_name = var.tls_secret_name
  service_name    = "immich-frame"
}
