
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
        Interval: 30
        ImageZoom: true
        ShowAlbumName: false
        ShowProgressBar: false
        WeatherApiKey: ${data.vault_kv_secret_v2.secrets.data["frame_weather_api_key"]}
        UnitSystem: metric
        WeatherLatLong: "51.5074,-0.1278"
        Language: en
    Accounts:
        - ImmichServerUrl: http://immich.viktorbarzin.me
          ApiKey: ${data.vault_kv_secret_v2.secrets.data["frame_api_key"]}
          ImagesFromDays: 730
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
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["keel.sh/match-tag"],
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
      spec[0].template[0].spec[0].container[0].image,                     # KEEL_IGNORE_IMAGE
    ]
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
  source = "../../modules/kubernetes/ingress_factory"
  # Photo-frame kiosk display — runs in headless browser mode on a TV/frame
  # device and pulls images via an Immich API key (no user login). Forward-auth
  # would 302 the device to Authentik with no way to complete login.
  # auth = "none": Photo-frame kiosk display — headless browser with API key; no user login; forward-auth breaks device automation.
  auth            = "none"
  dns_type        = "proxied"
  namespace       = "immich"
  name            = "highlights-immich"
  tls_secret_name = var.tls_secret_name
  service_name    = "immich-frame"
}
