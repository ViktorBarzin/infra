# =============================================================================
# myprotein-watch — tell Viktor when Impact Whey reaches his buying price
# =============================================================================
# Viktor buys Impact Whey only on a deep discount. His flavour, Cookies and
# Cream, was delisted from the Original line at some point after his May 2026
# order, so this watches for two things: any watched flavour reaching his
# £/serving price, and plain Cookies and Cream returning to the catalogue.
#
# Threshold rationale: his three Cookies and Cream orders were £0.650, £0.569
# and £0.628 per serving — 35-43% off RRP. A literal "50% off" rule would have
# blocked all three, so the trigger is £/serving, not headline discount.
#
# Four triggers (2026-08-15): the £/serving one above; "cheapest we have ever
# recorded" per SKU, which ignores RRP entirely and so cannot be fooled by RRP
# drift or pack-size changes; MyProtein's own displayed discount at 40%+; and
# plain Cookies and Cream returning to the Original line.
#
# Shape: stock python:3.12-alpine running pure-stdlib check.py from a ConfigMap.
# No pip/apk at runtime (the status-page-pusher disk anti-pattern, memory #559),
# no image to build, no login — MyProtein ships every variant's price as embedded
# JSON on the public product page, so a plain HTTP GET is enough.
#
# READ-ONLY by design: it fetches a public page and posts to Slack. It never
# authenticates to MyProtein, touches a basket, or places an order.
#
# State (what we already alerted on) lives in a ConfigMap the job patches via
# the in-cluster API — ~200 bytes, not worth a PV or an NFS export.
# =============================================================================

locals {
  name = "myprotein-watch"
  labels = {
    app = local.name
  }
}

resource "kubernetes_namespace_v1" "myprotein_watch" {
  metadata {
    name = local.name
    labels = {
      name = local.name
      # Tier 4-aux: a tiny, off-path scheduled job.
      tier = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# -----------------------------------------------------------------------------
# Slack — reuses the Alertmanager incoming webhook (#alerts). No new webhook.
# -----------------------------------------------------------------------------
resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = local.name
      namespace = kubernetes_namespace_v1.myprotein_watch.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = local.name
      }
      data = [{
        secretKey = "SLACK_WEBHOOK_URL"
        remoteRef = {
          key      = "platform"
          property = "alertmanager_slack_api_url"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace_v1.myprotein_watch]
}

# -----------------------------------------------------------------------------
# The checker + its state
# -----------------------------------------------------------------------------
resource "kubernetes_config_map_v1" "script" {
  metadata {
    name      = "${local.name}-script"
    namespace = kubernetes_namespace_v1.myprotein_watch.metadata[0].name
  }
  data = {
    "check.py" = file("${path.module}/check.py")
  }
}

resource "kubernetes_config_map_v1" "state" {
  metadata {
    name      = "${local.name}-state"
    namespace = kubernetes_namespace_v1.myprotein_watch.metadata[0].name
  }
  data = {
    "state.json" = "{}"
  }
  lifecycle {
    # The CronJob owns this content — it records which deals it has already
    # announced. Terraform creates it empty and then keeps its hands off.
    ignore_changes = [data]
  }
}

resource "kubernetes_service_account_v1" "watcher" {
  metadata {
    name      = local.name
    namespace = kubernetes_namespace_v1.myprotein_watch.metadata[0].name
  }
}

resource "kubernetes_role_v1" "state_writer" {
  metadata {
    name      = "${local.name}-state-writer"
    namespace = kubernetes_namespace_v1.myprotein_watch.metadata[0].name
  }
  rule {
    api_groups     = [""]
    resources      = ["configmaps"]
    resource_names = [kubernetes_config_map_v1.state.metadata[0].name]
    verbs          = ["get", "patch"]
  }
}

resource "kubernetes_role_binding_v1" "state_writer" {
  metadata {
    name      = "${local.name}-state-writer"
    namespace = kubernetes_namespace_v1.myprotein_watch.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.state_writer.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.watcher.metadata[0].name
    namespace = kubernetes_namespace_v1.myprotein_watch.metadata[0].name
  }
}

# -----------------------------------------------------------------------------
# Every 6 hours — MyProtein sales are often short, and four public GETs a day
# costs nothing. Off the hour so it doesn't pile onto the cron rush.
# -----------------------------------------------------------------------------
resource "kubernetes_cron_job_v1" "check" {
  metadata {
    name      = local.name
    namespace = kubernetes_namespace_v1.myprotein_watch.metadata[0].name
    labels    = local.labels
  }
  spec {
    schedule                      = "23 */6 * * *"
    timezone                      = "Europe/London"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    starting_deadline_seconds     = 600

    job_template {
      metadata {
        labels = local.labels
      }
      spec {
        backoff_limit              = 2
        ttl_seconds_after_finished = 86400

        template {
          metadata {
            labels = local.labels
          }
          spec {
            restart_policy       = "OnFailure"
            service_account_name = kubernetes_service_account_v1.watcher.metadata[0].name

            container {
              name              = "check"
              image             = "docker.io/library/python:3.12-alpine"
              image_pull_policy = "IfNotPresent"
              command           = ["python3", "/scripts/check.py"]

              env {
                name = "SLACK_WEBHOOK_URL"
                value_from {
                  secret_key_ref {
                    name = local.name
                    key  = "SLACK_WEBHOOK_URL"
                  }
                }
              }
              env {
                name  = "STATE_BACKEND"
                value = "configmap"
              }
              env {
                name  = "STATE_TARGET"
                value = kubernetes_config_map_v1.state.metadata[0].name
              }
              # Viktor's buying price, from his own order history (£0.569-£0.650
              # per serving across three Cookies and Cream orders).
              env {
                name  = "THRESHOLD_PER_SERVING"
                value = "0.65"
              }
              # A big sale on MyProtein's own reckoning. Supplements the
              # £/serving trigger rather than replacing it: RRP is their number
              # and it drifts upward, and the Original line currently reads 0%
              # off while still being the dearest per serving.
              env {
                name  = "DEEP_DISCOUNT_PCT"
                value = "40"
              }
              # Cheapest-ever needs a price to be meaningfully better than the
              # record before it is worth saying — 1% keeps rounding noise quiet.
              env {
                name  = "NEW_LOW_MARGIN"
                value = "0.01"
              }
              # Cookies and Cream is the favourite; the rest are flavours he
              # said he wants to try (2026-08-15).
              env {
                name  = "WATCH_FLAVOURS"
                value = "Cookies and Cream,Cookie Crumble,Banana,Strawberry Cream"
              }

              volume_mount {
                name       = "script"
                mount_path = "/scripts"
                read_only  = true
              }

              resources {
                requests = {
                  cpu    = "10m"
                  memory = "48Mi"
                }
                limits = {
                  memory = "128Mi"
                }
              }
            }

            volume {
              name = "script"
              config_map {
                name = kubernetes_config_map_v1.script.metadata[0].name
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
