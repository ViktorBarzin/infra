# Immich photo-frame for Milka (milka.barzina@gmail.com) — a third instance,
# cloned from frame-emo.tf, scoped to Milka's own Immich account and Valchedrym
# weather. Served at highlights-immich-milka.viktorbarzin.me and shown on her
# Portal Mini (Valchedrym LAN 192.168.0.228) via the portal-immich-frame app,
# built with -PframeUrl=https://highlights-immich-milka.viktorbarzin.me.
#
# API key: Vault secret/emo -> immich_api_key_milka. It lives under emo's path
# rather than secret/immich because secret/immich is admin-only and emo cannot
# write there; move it alongside the other frame keys if that ever changes.
# The key is READ-ONLY by construction (asset/album/timeline read + view +
# download, no write or delete scopes) so the frame can never alter her library.
# It MUST include face.read: ImmichFrame fetches /api/faces per photo to centre
# the crop on faces, and without that scope Immich 403s and the frame answers
# 500 on every cycle while still showing the photo. Minted without it on
# 2026-08-06 and added on 2026-08-22 once the live 500s surfaced — the six
# endpoints checked at mint time did not include this one.
#
# Her account has 3149 assets and ZERO albums, so this frame is account-wide on
# a date window instead of album-filtered like Emo's. Note that a large share of
# those assets are WhatsApp-received images; curating them the way frame-emo
# does (keep/drop albums + the frame-sync CronJob) is a sensible follow-up.

data "vault_kv_secret_v2" "emo_immich_frame_milka" {
  mount = "secret"
  name  = "emo/immich_api_key_milka"
}

resource "kubernetes_config_map" "frame_config_milka" {
  metadata {
    name      = "config-milka"
    namespace = "immich"

    labels = {
      app = "frame-config-milka"
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
        # date-fns renders "eee, MMM d" as "нед, авг 23" under bg — Bulgarian
        # words in English order. Day before month is the natural order here.
        ClockDateFormat: "eee, d MMM"
        WeatherApiKey: ${data.vault_kv_secret_v2.secrets.data["frame_weather_api_key"]}
        UnitSystem: metric
        WeatherLatLong: "43.6833,23.4667"
        # Milka reads Bulgarian. This is a locale code, not a UI translation:
        # ImmichFrame ships no string catalogue, and passes this to date-fns for
        # the clock date and to OpenWeatherMap as its `lang` (verified live:
        # lang=bg returns "ясно небе" and the town as Вълчедръм). date-fns has
        # no "en" export, so the previous value was silently falling back to
        # enUS — "bg" is a real export and does resolve.
        Language: bg
        # How long ImmichFrame holds its cached copy of the ExcludedAlbums
        # asset list, in hours. Only that list is cached — AllAssetsPool asks
        # Immich for a fresh random batch on every frame and then filters it,
        # so this interval is exactly how long a newly-excluded photo can keep
        # appearing after frame_sync_milka.py adds it. The default of 12 means
        # the weekly sync would not fully take effect until Sunday afternoon.
        #
        # Not 0: RefreshInterval() maps a non-positive value to a 1 ms TTL,
        # which would re-fetch the whole exclusion list on every photo.
        # Nothing else reads this cache but the AllAssetsPool asset-count
        # statistic, so one extra call an hour is the entire cost.
        #
        # RenewImagesDuration is a different setting — days, and it governs the
        # on-disk DownloadImages file cache. It does not affect exclusions.
        RefreshAlbumPeopleInterval: 1
    Accounts:
        - ImmichServerUrl: http://immich.viktorbarzin.me
          ApiKey: ${data.vault_kv_secret_v2.emo_immich_frame_milka.data["key"]}
          # 1825 days covers essentially the whole library; it spans 2012-2026
          # but is overwhelmingly 2024-2026.
          ImagesFromDays: 1825
          # Skip the chat/greeting-card/screenshot album. Her library arrives
          # mostly through Viber, so a large share of it is forwarded greeting
          # cards, joke text-images, courier-app screenshots and conversation
          # captures — none of which belong on a photo frame.
          ExcludedAlbums:
            - 0d174625-d279-49dd-a446-0eaeda03d7ff
    EOF
  }
}


resource "kubernetes_deployment" "immich-frame-milka" {
  metadata {
    name      = "immich-frame-milka"
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
        app = "immich-frame-milka"
      }
    }
    strategy {
      type = "RollingUpdate"
    }
    template {
      metadata {
        labels = {
          app = "immich-frame-milka"
        }
        annotations = {
          "dependency.kyverno.io/wait-for" = "immich-server.immich:2283"
        }
      }
      spec {
        container {
          # Pinned: releases <= v1.0.33.0 crash on Immich v3 API responses, and
          # album filtering needs >= v1.0.34.0.
          image = "ghcr.io/immichframe/immichframe:v1.0.35.0"
          # IfNotPresent, deliberately NOT "Always" like frame-emo: the Kyverno
          # set-image-pull-policy ClusterPolicy rewrites pinned tags to
          # IfNotPresent at admission, so declaring "Always" makes Terraform
          # re-detect drift and restart the pod on every apply of this stack.
          # A pinned tag does not need Always to stay fresh.
          image_pull_policy = "IfNotPresent"
          name              = "immich-frame-milka"
          resources {
            requests = {
              cpu    = "10m"
              memory = "128Mi"
            }
            limits = {
              # 128Mi OOM-looped the kiosk renderer on frame-emo (steady ~89Mi,
              # spikes past 128Mi on image load) — same headroom here.
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
            name = "config-milka"
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
    ]
  }
}


resource "kubernetes_service" "immich-frame-milka" {
  metadata {
    name      = "immich-frame-milka"
    namespace = "immich"
    labels = {
      "app" = "immich-frame-milka"
    }
  }

  spec {
    selector = {
      app = "immich-frame-milka"
    }
    port {
      port        = 80
      target_port = 8080
    }
  }
}

module "ingress_milka" {
  source = "../../modules/kubernetes/ingress_factory"
  # Photo-frame kiosk on Milka's Portal Mini (Valchedrym LAN, reached over the
  # WireGuard spoke). Same gating as the other two frames: home-lans-only
  # ipAllowList + dns_type "internal". 192.168.0.0/24 is already in that
  # allowlist, and the Valchedrym router masquerades onto the tunnel so Traefik
  # sees 10.3.2.5 — inside 10.0.0.0/8, allowed either way.
  # NOTE: the Valchedrym router's dnsmasq had rebind_protection on, which
  # stripped the RFC1918 answer for internal-DNS hosts; fixed 2026-08-06 with
  # rebind_domain='viktorbarzin.me' on that router.
  # auth = "none": kiosk WebView, no user auth by design; gated by the home-lans-only ipAllowList instead.
  auth     = "none"
  dns_type = "internal"
  # Ordering matters: error-pages-403 only intercepts what is downstream of
  # it, so it must precede the allowlist. Same as frame.tf / frame-emo.tf.
  extra_middlewares = ["traefik-error-pages-403@kubernetescrd", "traefik-home-lans-only@kubernetescrd"]
  # Not externally reachable — explicit opt-out so external-monitor-sync does
  # not opt it back in.
  external_monitor = false
  namespace        = "immich"
  name             = "highlights-immich-milka"
  tls_secret_name  = var.tls_secret_name
  service_name     = "immich-frame-milka"
  extra_annotations = {
    "gethomepage.dev/description" = "Immich photo frame feed for Milka's kiosk in Valchedrym"
    "gethomepage.dev/icon"        = "immich.png"
    "gethomepage.dev/name"        = "Immich Highlights (Milka)"
  }
}
