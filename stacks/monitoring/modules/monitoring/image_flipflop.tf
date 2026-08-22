# =============================================================================
# Image-ownership conflict detector
# =============================================================================
# Finds Deployments whose container image is being rewritten in a loop by two
# owners — most often Keel versus whatever declares the image (a Terraform
# helm_release, a raw kubernetes_deployment, the authentik server).
#
# This is the BACKSTOP half of the 2026-08-16 fix. The preventive half is the
# Kyverno rule `keel-never-when-another-owner`, which stamps
# keel.sh/policy=never on any workload declaring `app.kubernetes.io/managed-by`.
# That label undercounts — a raw kubernetes_deployment carries no such label —
# so this job keys on observed BEHAVIOUR instead: a Deployment that produced
# >= 3 ReplicaSets in 24h AND put back an image set it had already replaced.
#
# Why it needs to exist at all: the fight is silent by construction. Keel logs
# an ordinary "resource updated", the other owner logs an ordinary reconcile,
# and neither knows the other exists. Every instance so far was found only via
# an unrelated downstream symptom — a flapping alert (prometheus-server, whose
# hourly restarts reset every alert `for:` timer), a dropped VPN tunnel
# (proxy-gw-1), or not at all: authentik/ak-outpost-public sat at deployment
# generation 497, being DOWNGRADED every ~4h, entirely unnoticed.
#
# Verified against live cluster state on 2026-08-16: 1,980 ReplicaSets scanned,
# exactly the three known offenders returned, no false positives. The detector's
# discrimination between a fight and ordinary deploy churn (monotonic upgrades,
# repeated identical images, container reordering, single rollbacks) is covered
# by image_flipflop_detect_test.py — run `python3 image_flipflop_detect_test.py`.
# =============================================================================

resource "kubernetes_service_account" "image_flipflop_detect" {
  metadata {
    name      = "image-flipflop-detect"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
}

# Read-only, and only ReplicaSets: the detector never needs pods, secrets or
# any write verb. It reads cluster-wide because an ownership fight can happen
# in any namespace.
resource "kubernetes_cluster_role" "image_flipflop_detect" {
  metadata {
    name = "image-flipflop-detect"
  }
  rule {
    api_groups = ["apps"]
    resources  = ["replicasets"]
    verbs      = ["get", "list"]
  }
}

resource "kubernetes_cluster_role_binding" "image_flipflop_detect" {
  metadata {
    name = "image-flipflop-detect"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.image_flipflop_detect.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.image_flipflop_detect.metadata[0].name
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
}

resource "kubernetes_config_map" "image_flipflop_detect_script" {
  metadata {
    name      = "image-flipflop-detect-script"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }
  data = {
    "image_flipflop_detect.py" = file("${path.module}/image_flipflop_detect.py")
  }
}

resource "kubernetes_cron_job_v1" "image_flipflop_detect" {
  metadata {
    name      = "image-flipflop-detect"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      app  = "image-flipflop-detect"
      tier = var.tier
    }
  }
  spec {
    concurrency_policy            = "Forbid"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 3
    # Every 6h. The detection window is 24h, so this is about how fast a new
    # fight surfaces, not about catching it at all — 4 pod creations/day is
    # negligible and a fight that starts right after a run is still reported
    # well within the day.
    schedule                  = "0 */6 * * *"
    starting_deadline_seconds = 600
    job_template {
      metadata {}
      spec {
        backoff_limit              = 2
        ttl_seconds_after_finished = 86400
        template {
          metadata {
            labels = {
              app = "image-flipflop-detect"
            }
          }
          spec {
            restart_policy       = "OnFailure"
            service_account_name = kubernetes_service_account.image_flipflop_detect.metadata[0].name
            container {
              name              = "image-flipflop-detect"
              image             = "docker.io/library/python:3.12-alpine"
              image_pull_policy = "IfNotPresent"
              command           = ["python3", "/scripts/image_flipflop_detect.py"]
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
                  # MEASURED, not guessed (2026-08-16): listing every
                  # ReplicaSet cluster-wide is 1,980 objects / ~18 MiB of
                  # JSON, and json.load peaks at ~75 MiB RSS. 192Mi is ~2.5x
                  # that. Under-sizing this is not cosmetic — the helm-unstick
                  # CronJob was memcg-OOM-killed on every run at 96Mi and its
                  # `|| true` turned that into a silent empty result, so the
                  # job reported success while inspecting nothing. Re-measure
                  # rather than assume if the cluster's ReplicaSet count grows
                  # a lot (revisionHistoryLimit x deployment count).
                  memory = "192Mi"
                }
              }
            }
            volume {
              name = "script"
              config_map {
                name = kubernetes_config_map.image_flipflop_detect_script.metadata[0].name
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
