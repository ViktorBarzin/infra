locals {
  namespace = "travel-agent"
  image     = "forgejo.viktorbarzin.me/viktor/travel-agent:${var.image_tag}"
  labels = {
    app = "travel-agent"
  }

  # Two workflows, both scheduled in Europe/London (K8s 1.27+ honours timeZone).
  workflows = {
    "flight-train-check" = {
      schedule = "0 8 * * *"
      arg      = "flight_train_check"
    }
    "trip-weather-brief" = {
      schedule = "0 21 * * *"
      arg      = "trip_weather_brief"
    }
  }
}

resource "kubernetes_namespace" "travel_agent" {
  metadata {
    name = local.namespace
    labels = {
      tier              = local.tiers.aux
      "istio-injection" = "disabled"
      # Opt into Keel auto-update (inject-keel-annotations ClusterPolicy).
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# App secrets — seed these in Vault before applying:
#   secret/travel-agent
#     nextcloud_caldav_url   — CalDAV collection URL (Nextcloud)
#     nextcloud_caldav_user  — CalDAV username
#     nextcloud_caldav_pass  — CalDAV app password
#     slack_webhook_url      — incoming-webhook URL for the target channel
resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "travel-agent-secrets"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name           = "travel-agent-secrets"
        creationPolicy = "Owner"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
        }
      }
      data = [
        {
          secretKey = "NEXTCLOUD_CALDAV_URL"
          remoteRef = { key = "travel-agent", property = "nextcloud_caldav_url" }
        },
        {
          secretKey = "NEXTCLOUD_CALDAV_USER"
          remoteRef = { key = "travel-agent", property = "nextcloud_caldav_user" }
        },
        {
          secretKey = "NEXTCLOUD_CALDAV_PASS"
          remoteRef = { key = "travel-agent", property = "nextcloud_caldav_pass" }
        },
        {
          secretKey = "SLACK_WEBHOOK_URL"
          remoteRef = { key = "travel-agent", property = "slack_webhook_url" }
        },
      ]
    }
  }
  depends_on = [kubernetes_namespace.travel_agent]
}

resource "kubernetes_cron_job_v1" "workflow" {
  for_each = local.workflows

  metadata {
    name      = "travel-agent-${each.key}"
    namespace = kubernetes_namespace.travel_agent.metadata[0].name
    labels = merge(local.labels, {
      component = each.key
    })
  }

  spec {
    schedule                      = each.value.schedule
    timezone                      = "Europe/London"
    concurrency_policy            = "Forbid"
    starting_deadline_seconds     = 300
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 5

    job_template {
      metadata {
        labels = merge(local.labels, {
          component = each.key
        })
      }
      spec {
        backoff_limit              = 1
        ttl_seconds_after_finished = 86400
        template {
          metadata {
            labels = merge(local.labels, {
              component = each.key
            })
          }
          spec {
            restart_policy = "OnFailure"
            image_pull_secrets {
              name = "registry-credentials"
            }
            container {
              name  = "runner"
              image = local.image
              args  = [each.value.arg]
              env_from {
                secret_ref { name = "travel-agent-secrets" }
              }
              resources {
                requests = { cpu = "100m", memory = "128Mi" }
                limits   = { memory = "256Mi" }
              }
            }
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      spec[0].job_template[0].spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      # Keel manages tag updates on enrolled namespaces.
      spec[0].job_template[0].spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE
    ]
  }

  depends_on = [kubernetes_manifest.external_secret]
}
