
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
        ClockFormat: "HH:mm"
        PhotoDateFormat: "dd/MM/yyyy"
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
          # immich_v3 is the upstream compat tag for Immich v3 servers — every
          # versioned release (≤ v1.0.33.0) crashes deserializing v3 API
          # responses (immichFrame/immichFrame#653). Pin back to a vX.Y.Z.W tag
          # once a stable release ships v3 support (upstream PR #654).
          image = "ghcr.io/immichframe/immichframe:immich_v3"
          name  = "immich-frame"
          resources {
            requests = {
              cpu    = "10m"
              memory = "128Mi"
            }
            limits = {
              # Matches frame-emo: 128Mi OOM-loops the kiosk renderer on image
              # load — raised to 256Mi 2026-07-06.
              memory = "256Mi"
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
  # Photo-frame kiosk display (Viktor's London Portal Plus WebView) — pulls
  # images via an Immich API key; no user login possible on the device, so
  # forward-auth would 302 it to Authentik with no way to complete login.
  # The GATE is network-level: the home-lans-only ipAllowList (Sofia/London/
  # Valchedrym LANs + 10/8) 403s everyone else, and dns_type "internal"
  # publishes the Traefik LB IP publicly so the Portal's baked-in URL resolves
  # from any resolver yet routes only via the home LANs / WG tunnel.
  # LAN-only design: docs/plans/2026-07-04-immich-frame-lan-only-design.md.
  # auth = "none": kiosk WebView, no user auth by design; gated by the home-lans-only ipAllowList instead.
  auth              = "none"
  dns_type          = "internal"
  extra_middlewares = ["traefik-home-lans-only@kubernetescrd"]
  # Not externally reachable — explicit opt-out so external-monitor-sync
  # drops the old [External] monitor instead of default-opting it back in.
  external_monitor = false
  namespace        = "immich"
  name             = "highlights-immich"
  tls_secret_name  = var.tls_secret_name
  service_name     = "immich-frame"
}
