# =============================================================================
# Helm "pending-upgrade" auto-heal  (the #6073 recurring class)
# =============================================================================
# A Woodpecker pipeline SIGKILLed mid `helm upgrade` (cancel-on-new-push) leaves
# the release's newest revision Secret stuck status=pending-upgrade. helm reads
# the MAX revision, so that wedge blocks every later upgrade of the release
# ("another operation in progress") AND the later stacks behind it in the same
# CI run (2026-07-26: immich never applied behind a wedged prometheus rev, and
# the same session wedged prometheus 4x from concurrent pushes).
#
# prometheus.tf now sets wait=false so helm no longer babysits the slow
# Recreate+WAL-replay roll (shrinking the SIGKILL window ~15min -> ~2s). This
# CronJob is the safety net for the residual + the crowdsec/nextcloud known-issue
# class (memory #51/#131/#8315). Detection already exists (cluster_healthcheck
# #18 flags `pending`); this closes the loop by auto-clearing.
#
# The fix is the documented non-disruptive one (memory #6073): delete the dead
# pending-upgrade revision Secret so helm falls back to the prior `deployed`
# rev. The live workload (already rolled during the killed upgrade) is untouched.
#
# SAFETY (see helm_unstick.sh for the guards): only ever deletes a Secret that
# is a helm record (owner=helm) + status=pending-upgrade + older than the
# threshold (> any legit helm --wait here, so an in-flight upgrade is never
# touched) + whose release still has a `deployed` revision to fall back to.
# RBAC is scoped per-namespace to an explicit allow-list — no cluster-wide
# secret access. (authentik/kyverno/metrics-server are deliberately excluded:
# their wedges were ancient one-offs, not recurring, and they hold far more
# sensitive secrets — a rare wedge there is cleared by hand off cluster_healthcheck #18.)
# =============================================================================

locals {
  # Namespaces whose helm releases recurrently wedge in pending-upgrade.
  # Add a namespace here (and it gets a scoped Role) if a new release joins the club.
  helm_unstick_namespaces = ["monitoring", "crowdsec", "nextcloud"]
}

resource "kubernetes_service_account" "helm_unstick" {
  metadata {
    name      = "helm-unstick"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
}

# Per-namespace: list helm release secrets + delete the wedged ones. Scoped Role
# (not ClusterRole) so the job can only touch secrets in the allow-listed namespaces.
resource "kubernetes_role" "helm_unstick" {
  for_each = toset(local.helm_unstick_namespaces)
  metadata {
    name      = "helm-unstick"
    namespace = each.value
  }
  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["get", "list", "delete"]
  }
}

resource "kubernetes_role_binding" "helm_unstick" {
  for_each = toset(local.helm_unstick_namespaces)
  metadata {
    name      = "helm-unstick"
    namespace = each.value
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.helm_unstick[each.value].metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.helm_unstick.metadata[0].name
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
}

resource "kubernetes_config_map" "helm_unstick_script" {
  metadata {
    name      = "helm-unstick-script"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = {
    "helm_unstick.sh" = file("${path.module}/helm_unstick.sh")
  }
}

resource "kubernetes_cron_job_v1" "helm_unstick" {
  metadata {
    name      = "helm-unstick"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      app  = "helm-unstick"
      tier = var.tier
    }
  }
  spec {
    concurrency_policy            = "Forbid"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 3
    schedule                      = "*/15 * * * *"
    starting_deadline_seconds     = 300
    job_template {
      metadata {}
      spec {
        backoff_limit              = 1
        ttl_seconds_after_finished = 86400
        template {
          metadata {
            labels = {
              app = "helm-unstick"
            }
          }
          spec {
            service_account_name = kubernetes_service_account.helm_unstick.metadata[0].name
            restart_policy       = "OnFailure"
            container {
              name    = "helm-unstick"
              image   = "bitnami/kubectl:latest"
              command = ["bash", "/scripts/helm_unstick.sh"]
              env {
                name  = "NAMESPACES"
                value = join(" ", local.helm_unstick_namespaces)
              }
              env {
                name  = "THRESHOLD_SECONDS"
                value = "1800"
              }
              env {
                # Safety valve: set to "true" to log WOULD-CLEAR without deleting.
                name  = "DRY_RUN"
                value = "false"
              }
              volume_mount {
                name       = "script"
                mount_path = "/scripts"
                read_only  = true
              }
              # kubectl buffers every matched Secret in memory before the
              # jsonpath projection runs, so this scales with the number of
              # helm REVISIONS retained, and that number only grows.
              #
              # 2026-08-08: 61 records in monitoring, ~128 MiB peak. The 96Mi
              # ceiling of the day memcg-OOM-killed kubectl on EVERY run, which
              # a `|| true` swallowed into an empty result, so the job reported
              # success while inspecting nothing. Limit went to 256Mi, "2x the
              # measured peak so revision growth does not silently re-break it".
              #
              # 2026-09-19: it re-broke, and not silently this time. 152 records
              # in monitoring, measured peak 219 MiB against that 256Mi — 85% of
              # the ceiling, so a run tipped over whenever the payload was a
              # little larger. 12 of 96 runs a day were OOM-killed, and because
              # the script prints nothing until its final summary line, a killed
              # attempt left NO output at all: the only visible symptom was a
              # Job marked Failed with an empty log. Each one raised a JobFailed
              # AND a CronJobFailingRepeatedly, 13 of the 31 job alerts a day.
              #
              # 512Mi is 2x the new measured peak, on the same rule as before.
              # That rule bought 42 days last time (61 -> 152 records at about
              # 1 MiB each), and records still grow about 2 a day (160 on
              # 2026-09-23), so this lasts roughly four months. --chunk-size does NOT help
              # (20-item pages measured 208 MiB against 219 unpaged) because
              # -o jsonpath accumulates the whole list regardless of paging. The
              # durable fix is to stop fetching the secret BODIES at all, since
              # the script reads only labels and creationTimestamp: a
              # PartialObjectMetadataList request, as stray_workload_detect
              # already does in this same namespace, holds metadata only.
              resources {
                requests = {
                  cpu    = "10m"
                  memory = "96Mi"
                }
                limits = {
                  memory = "512Mi"
                }
              }
            }
            volume {
              name = "script"
              config_map {
                name = kubernetes_config_map.helm_unstick_script.metadata[0].name
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
