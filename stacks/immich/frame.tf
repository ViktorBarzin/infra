
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
        - ImmichServerUrl: https://immich.viktorbarzin.me
          ApiKey: ${data.vault_kv_secret_v2.secrets.data["frame_api_key"]}
          # 4 years (was 730). ImmichFrame draws 25 random assets per batch and keeps
          # no record of what it showed, so repeats scale with 1/pool: 730 days left
          # 25,950 of 57,001 images and gave 29 repeats in 10.2h measured 2026-09-12;
          # 1460 gives 47,983 over 954 days and about half that.
          ImagesFromDays: 1460
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
          # Versioned pin, same release as frame-emo/frame-milka. Releases
          # <= v1.0.33.0 crashed deserializing Immich v3 API responses
          # (immichFrame/immichFrame#653), so this ran the floating immich_v3
          # compat tag until 2026-10-12; v1.0.34+ supports Immich v3.
          image = "ghcr.io/immichframe/immichframe:v1.0.39.0@sha256:b4bd2ac6ec75c0117a24bd627dc0b449d485ac87ec3a410c73d5db05a4bbfcaf"
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
          # From v1.0.38 ImmichFrame keeps its settings in a SQLite DB
          # (immichframe.db) in /app/Config and imports Settings.yml into it
          # only when the DB is empty, so a read-only ConfigMap mount there
          # crash-loops it. Same pattern as frame-emo.tf: /app/Config is a
          # writable emptyDir with Settings.yml mounted into it, every new pod
          # re-imports the file, and the ConfigMap stays the source of truth.
          volume_mount {
            name       = "data"
            mount_path = "/app/Config"
          }
          volume_mount {
            name       = "config"
            mount_path = "/app/Config/Settings.yml"
            sub_path   = "Settings.yml"
            read_only  = true
          }
        }
        volume {
          name = "data"
          empty_dir {}
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
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"],                      # LEGACY_TEMPLATE_ANNOTATIONS
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
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
  auth     = "none"
  dns_type = "internal"
  # error-pages-403 MUST precede the allowlist: it can only intercept responses
  # from what sits downstream of it, and home-lans-only short-circuits without
  # calling next. Turns the bare "Forbidden" a wrong-network visitor gets into
  # the themed error page.
  extra_middlewares = ["traefik-error-pages-403@kubernetescrd", "traefik-home-lans-only@kubernetescrd"]
  # Not externally reachable — explicit opt-out so external-monitor-sync
  # drops the old [External] monitor instead of default-opting it back in.
  external_monitor = false
  namespace        = "immich"
  name             = "highlights-immich"
  tls_secret_name  = var.tls_secret_name
  service_name     = "immich-frame"
  extra_annotations = {
    "gethomepage.dev/description" = "Immich photo frame feed for the kiosks"
    "gethomepage.dev/icon"        = "immich.png"
    "gethomepage.dev/name"        = "Immich Highlights"
  }
}
