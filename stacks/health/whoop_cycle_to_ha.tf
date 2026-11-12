############################################################################
# whoop-cycle-to-ha — Anca's menstrual cycle phase on ha-london.
#
# Anca logs her period in WHOOP (Menstrual Cycle Insights). WHOOP's public
# developer API carries no menstrual data, and WHOOP does not write it to
# Health Connect, so this reads the private endpoint the WHOOP app uses:
#   GET api.prod.whoop.com/womens-health-service/v1/menstrual-cycle-insights
# with a token from WHOOP's Cognito proxy (email + password login). The
# endpoint and login flow come from github.com/briangaoo/whoop-mcp. It is
# unofficial and against WHOOP's terms, so it can break whenever WHOOP changes
# its app, and carries a (low, accepted) risk to Anca's paid account.
#
# To keep the footprint on that account minimal, it runs ONCE A MONTH: one
# login, one read. It writes the cycle anchor into persisted HA helpers
# (input_datetime.anca_cycle_start, input_number.anca_cycle_length /
# anca_period_length, input_datetime.anca_cycle_last_sync); the template sensor
# in ha-london packages/anca_cycle.yaml advances sensor.anca_cycle_phase and
# sensor.anca_cycle_day LOCALLY every day from those helpers, so the phase stays
# current with no further WHOOP traffic. The script jitters its start time
# (JITTER_SECONDS) so the request does not land on a clock boundary, and sends
# the WHOOP app's own identity headers.
#
# Recovery, HRV and sleep reach ha-london separately, through the official
# API and the HACS integration prankstr/hassio-whoop.
# Logic and tests: files/whoop_cycle_to_ha.py, files/test_whoop_cycle_to_ha.py.
############################################################################

resource "kubernetes_manifest" "whoop_cycle_to_ha_external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "whoop-cycle-to-ha"
      namespace = "health"
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "whoop-cycle-to-ha"
        template = {
          data = {
            WHOOP_EMAIL           = "{{ .email }}"
            WHOOP_PASSWORD        = "{{ .password }}"
            WHOOP_INSTALLATION_ID = "{{ .installation_id }}"
            # Gmail app password to read + delete the WHOOP login-code email.
            GMAIL_USER         = "{{ .email }}"
            GMAIL_APP_PASSWORD = "{{ .gmail_app_password }}"
            # ha-london long-lived token from its canonical home (secret/openclaw
            # -> skill_secrets JSON, key home_assistant_token = London).
            HA_TOKEN = "{{ .skill_secrets | fromJson | dig \"home_assistant_token\" \"\" }}"
          }
        }
      }
      data = [
        {
          secretKey = "email"
          remoteRef = { key = "whoop-anca", property = "email" }
        },
        {
          secretKey = "password"
          remoteRef = { key = "whoop-anca", property = "password" }
        },
        {
          secretKey = "installation_id"
          remoteRef = { key = "whoop-anca", property = "installation_id" }
        },
        {
          secretKey = "gmail_app_password"
          remoteRef = { key = "whoop-anca", property = "gmail_app_password" }
        },
        {
          secretKey = "skill_secrets"
          remoteRef = { key = "openclaw", property = "skill_secrets" }
        },
      ]
    }
  }
  depends_on = [kubernetes_namespace.health]
}

# The script is shipped verbatim from files/; any change there re-applies this stack.
resource "kubernetes_config_map" "whoop_cycle_to_ha_script" {
  metadata {
    name      = "whoop-cycle-to-ha-script"
    namespace = kubernetes_namespace.health.metadata[0].name
  }
  data = {
    "whoop_cycle_to_ha.py" = file("${path.module}/files/whoop_cycle_to_ha.py")
  }
}

resource "kubernetes_cron_job_v1" "whoop_cycle_to_ha" {
  metadata {
    name      = "whoop-cycle-to-ha"
    namespace = kubernetes_namespace.health.metadata[0].name
  }

  spec {
    # 09:37 UTC on the 3rd of each month; the script then sleeps a random
    # 0-60 min (JITTER_SECONDS) so the one monthly WHOOP request does not land
    # on a predictable boundary.
    schedule                      = "37 9 3 * *"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    concurrency_policy            = "Forbid"
    starting_deadline_seconds     = 300

    job_template {
      metadata {}
      spec {
        # Must exceed the jitter window (3600s) plus the work.
        active_deadline_seconds    = 4200
        backoff_limit              = 1
        ttl_seconds_after_finished = 3600
        template {
          metadata {
            labels = {
              app = "whoop-cycle-to-ha"
            }
          }
          spec {
            restart_policy = "Never"

            container {
              name = "whoop-cycle-to-ha"
              # python3 and requests come baked into job-runtime (images/job-runtime).
              image             = "ghcr.io/viktorbarzin/job-runtime:latest"
              image_pull_policy = "Always"
              command           = ["python3", "/scripts/whoop_cycle_to_ha.py"]
              env_from {
                secret_ref {
                  name = "whoop-cycle-to-ha"
                }
              }
              env {
                name  = "HA_URL"
                value = "https://ha-london.viktorbarzin.me"
              }
              env {
                name  = "JITTER_SECONDS"
                value = "3600"
              }
              volume_mount {
                name       = "script"
                mount_path = "/scripts"
                read_only  = true
              }
              resources {
                requests = {
                  cpu    = "10m"
                  memory = "64Mi"
                }
                limits = {
                  memory = "128Mi"
                }
              }
            }
            volume {
              name = "script"
              config_map {
                name = kubernetes_config_map.whoop_cycle_to_ha_script.metadata[0].name
              }
            }
          }
        }
      }
    }
  }
  depends_on = [kubernetes_manifest.whoop_cycle_to_ha_external_secret]
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}
