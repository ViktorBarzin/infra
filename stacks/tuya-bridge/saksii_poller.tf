# ─────────────────────────────────────────────────────────────────────────────
# "Саксии" live reader — WD-01ADE potted-plant watering controller.
#
# The official HA Tuya integration only exposes the two pump switches
# (switch.wd_01ade_switch_1/2). The schedule (timer1/2), per-channel watering
# duration (woter_timer1/2) and the run log live ONLY in the Tuya cloud
# "thing model" (shadow properties), which the integration does not surface.
#
# This CronJob polls the Tuya developer Cloud API every 5 min, decodes the raw
# timer blobs, and pushes the values into ha-sofia as sensor.*/binary_sensor.*
# entities via the HA REST API (POST /api/states). The "Напояване → Саксии"
# dashboard renders these live.
#
# Reuses:
#   * the tuya_bridge image (tinytuya + requests already installed — no build,
#     no runtime pip)
#   * the tuya-bridge-secrets ExternalSecret for the Tuya developer creds
#     (api_key / api_secret, region EU)
#
# PREREQUISITE (Viktor): add key `home_assistant_sofia_token` to the Vault
# entry behind ClusterSecretStore key `tuya-bridge` (value = the existing
# ha-sofia long-lived token, i.e. secret/openclaw -> skill_secrets
# .home_assistant_sofia_token). The existing tuya-bridge-secrets ExternalSecret
# (`dataFrom.extract key=tuya-bridge`) then picks it up automatically; no TF
# change needed here once the key exists.
# ─────────────────────────────────────────────────────────────────────────────

resource "kubernetes_config_map" "saksii_poller_script" {
  metadata {
    name      = "saksii-poller-script"
    namespace = kubernetes_namespace.tuya-bridge.metadata[0].name
  }
  data = {
    "poll.py" = file("${path.module}/files/saksii_poller.py")
  }
}

resource "kubernetes_cron_job_v1" "saksii_poller" {
  metadata {
    name      = "saksii-poller"
    namespace = kubernetes_namespace.tuya-bridge.metadata[0].name
    labels = {
      app  = "saksii-poller"
      tier = local.tiers.cluster
    }
  }
  spec {
    concurrency_policy            = "Forbid"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 1
    schedule                      = "*/5 * * * *"
    starting_deadline_seconds     = 300
    job_template {
      metadata {}
      spec {
        backoff_limit              = 1
        ttl_seconds_after_finished = 3600
        template {
          metadata {
            labels = {
              app = "saksii-poller"
            }
          }
          spec {
            restart_policy = "Never"
            image_pull_secrets {
              name = "registry-credentials"
            }
            image_pull_secrets {
              name = "ghcr-credentials"
            }
            container {
              name              = "saksii-poller"
              image             = "ghcr.io/viktorbarzin/tuya_bridge:latest"
              image_pull_policy = "Always"
              command           = ["python3", "/scripts/poll.py"]
              env {
                name = "TUYA_API_KEY"
                value_from {
                  secret_key_ref {
                    name = "tuya-bridge-secrets"
                    key  = "api_key"
                  }
                }
              }
              env {
                name = "TUYA_API_SECRET"
                value_from {
                  secret_key_ref {
                    name = "tuya-bridge-secrets"
                    key  = "api_secret"
                  }
                }
              }
              env {
                name = "HA_TOKEN"
                value_from {
                  secret_key_ref {
                    name = "tuya-bridge-secrets"
                    key  = "home_assistant_sofia_token"
                  }
                }
              }
              env {
                name  = "HA_URL"
                value = "https://ha-sofia.viktorbarzin.me"
              }
              env {
                name  = "TUYA_DEVICE_ID"
                value = "bfa58e4705a6e534c0nqut"
              }
              volume_mount {
                name       = "script"
                mount_path = "/scripts"
                read_only  = true
              }
              resources {
                requests = {
                  cpu    = "10m"
                  memory = "128Mi"
                }
                limits = {
                  memory = "128Mi"
                }
              }
            }
            volume {
              name = "script"
              config_map {
                name = kubernetes_config_map.saksii_poller_script.metadata[0].name
              }
            }
            dns_config {
              option {
                name  = "ndots"
                value = "2"
              }
            }
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}
