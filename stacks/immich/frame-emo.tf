# Immich photo-frame for Emo (emil.barzin@gmail.com) — a second instance cloned
# from the London frame in frame.tf, scoped to Emo's Immich account + Sofia
# weather. Served at highlights-immich-emo.viktorbarzin.me and shown on Emo's
# Portal Mini (Sofia) via the portal-immich-frame app.
# API key: Vault secret/immich -> frame_api_key_emo (minted on Emo's account).

resource "kubernetes_config_map" "frame_config_emo" {
  metadata {
    name      = "config-emo"
    namespace = "immich"

    labels = {
      app = "frame-config-emo"
    }
    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }

  data = {
    "Settings.yml" = <<-EOF
    General:
        Layout: single
        Interval: 45
        ImageZoom: true
        ShowAlbumName: false
        ShowProgressBar: false
        ClockFormat: "HH:mm"
        PhotoDateFormat: "dd/MM/yyyy"
        WeatherApiKey: ${data.vault_kv_secret_v2.secrets.data["frame_weather_api_key"]}
        UnitSystem: metric
        WeatherLatLong: "42.6977,23.3219"
        Language: en
    Accounts:
        - ImmichServerUrl: http://immich.viktorbarzin.me
          ApiKey: ${data.vault_kv_secret_v2.secrets.data["frame_api_key_emo"]}
          ImagesFromDays: 365
          ExcludedAlbums:
            - b703c7e1-943f-44c4-9ebb-ae3ee41473dd
    EOF
  }
}


resource "kubernetes_deployment" "immich-frame-emo" {
  metadata {
    name      = "immich-frame-emo"
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
        app = "immich-frame-emo"
      }
    }
    strategy {
      type = "RollingUpdate"
    }
    template {
      metadata {
        labels = {
          app = "immich-frame-emo"
        }
        annotations = {
          "dependency.kyverno.io/wait-for" = "immich-server.immich:2283"
        }
      }
      spec {
        container {
          # immich_v3: upstream compat tag for Immich v3 — see frame.tf for the
          # full story; repin to a versioned tag once upstream releases v3 support.
          image = "ghcr.io/immichframe/immichframe:immich_v3"
          name  = "immich-frame-emo"
          resources {
            requests = {
              cpu    = "10m"
              memory = "128Mi"
            }
            limits = {
              # 128Mi OOM-looped the kiosk renderer (steady ~89Mi, spikes past
              # 128Mi on image load) — raised to 256Mi 2026-07-06.
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
            name = "config-emo"
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


resource "kubernetes_service" "immich-frame-emo" {
  metadata {
    name      = "immich-frame-emo"
    namespace = "immich"
    labels = {
      "app" = "immich-frame-emo"
    }
  }

  spec {
    selector = {
      app = "immich-frame-emo"
    }
    port {
      port        = 80
      target_port = 8080
    }
  }
}

module "ingress_emo" {
  source = "../../modules/kubernetes/ingress_factory"
  # Photo-frame kiosk display on Emo's Portal Mini (Sofia LAN) — WebView
  # pulling images via an Immich API key; no user login possible on the
  # device. Same LAN-only gating as frame.tf: home-lans-only ipAllowList +
  # dns_type "internal" (Emo's Portal already resolves this host internally
  # via Technitium; the public internal-IP record covers any resolver).
  # LAN-only design: docs/plans/2026-07-04-immich-frame-lan-only-design.md.
  # auth = "none": kiosk WebView, no user auth by design; gated by the home-lans-only ipAllowList instead.
  auth              = "none"
  dns_type          = "internal"
  extra_middlewares = ["traefik-home-lans-only@kubernetescrd"]
  # Not externally reachable — explicit opt-out so external-monitor-sync
  # drops the old [External] monitor instead of default-opting it back in.
  external_monitor = false
  namespace        = "immich"
  name             = "highlights-immich-emo"
  tls_secret_name  = var.tls_secret_name
  service_name     = "immich-frame-emo"
}
