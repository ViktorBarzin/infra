############################################################################
# net-worth-to-ha — net worth on the Apple Watch (ADR-0034).
#
# Every 15 min at :04/:19/:34/:49, 2 min after the pg-sync sidecar's
# market-hours mirror (:02/:17/:32/:47, weekdays 07-21 UTC; hourly at :07
# otherwise), reads per-day totals from the wealthfolio_sync mirror and POSTs
# sensor.net_worth to ha-sofia. The HA Companion app turns the sensor into a watch corner
# complication: total on the inner line, daily change on the outer arc.
# Logic and tests: files/net_worth_to_ha.py, files/test_net_worth_to_ha.py.
#
# A state POSTed through /api/states is not persisted across an HA restart,
# so the 15-min cadence is also what restores the sensor after one.
############################################################################

# ha-sofia long-lived token, read from its canonical home (secret/openclaw ->
# skill_secrets JSON, the same value tuya-bridge and openclaw use).
resource "kubernetes_manifest" "ha_sofia_token_external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "ha-sofia-token"
      namespace = "wealthfolio"
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "ha-sofia-token"
        template = {
          data = {
            HA_TOKEN = "{{ .skill_secrets | fromJson | dig \"home_assistant_sofia_token\" \"\" }}"
          }
        }
      }
      data = [{
        secretKey = "skill_secrets"
        remoteRef = {
          key      = "openclaw"
          property = "skill_secrets"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.wealthfolio]
}

# The script is shipped verbatim from files/; any change there re-applies this stack.
resource "kubernetes_config_map" "net_worth_to_ha_script" {
  metadata {
    name      = "net-worth-to-ha-script"
    namespace = kubernetes_namespace.wealthfolio.metadata[0].name
  }
  data = {
    "net_worth_to_ha.py" = file("${path.module}/files/net_worth_to_ha.py")
  }
}

resource "kubernetes_cron_job_v1" "net_worth_to_ha" {
  metadata {
    name      = "net-worth-to-ha"
    namespace = kubernetes_namespace.wealthfolio.metadata[0].name
  }

  spec {
    schedule                      = "4,19,34,49 * * * *"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    concurrency_policy            = "Forbid"
    starting_deadline_seconds     = 300

    job_template {
      metadata {}
      spec {
        active_deadline_seconds    = 180
        backoff_limit              = 1
        ttl_seconds_after_finished = 3600
        template {
          metadata {
            labels = {
              app = "net-worth-to-ha"
            }
          }
          spec {
            restart_policy = "Never"

            container {
              name = "net-worth-to-ha"
              # python3 and psql come baked into job-runtime (images/job-runtime),
              # so the pod installs nothing on start.
              image             = "ghcr.io/viktorbarzin/job-runtime:latest"
              image_pull_policy = "Always"
              command           = ["python3", "/scripts/net_worth_to_ha.py"]
              env_from {
                secret_ref {
                  name = "wealthfolio-sync-db-creds"
                }
              }
              env_from {
                secret_ref {
                  name = "ha-sofia-token"
                }
              }
              env {
                name  = "HA_URL"
                value = "https://ha-sofia.viktorbarzin.me"
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
                name = kubernetes_config_map.net_worth_to_ha_script.metadata[0].name
              }
            }
          }
        }
      }
    }
  }
  depends_on = [kubernetes_manifest.ha_sofia_token_external_secret]
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}
