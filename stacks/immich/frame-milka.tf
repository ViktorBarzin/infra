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
        WeatherApiKey: ${data.vault_kv_secret_v2.secrets.data["frame_weather_api_key"]}
        UnitSystem: metric
        WeatherLatLong: "43.6833,23.4667"
        Language: en
    Accounts:
        - ImmichServerUrl: http://immich.viktorbarzin.me
          ApiKey: ${data.vault_kv_secret_v2.emo_immich_frame_milka.data["key"]}
          # 1825 days covers 3146 of her 3149 assets; her library spans
          # 2012-2025 but is overwhelmingly 2024-2025, and uploads appear to
          # have stopped in Dec 2025 (her phone backup needs re-enabling).
          ImagesFromDays: 1825
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
