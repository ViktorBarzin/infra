# ──────────────────────────────────────────────────────────────────────────────
# Postiz — social media post scheduler (Instagram Stories + others).
#
# Chart: oci://ghcr.io/gitroomhq/postiz-helmchart/charts/postiz (v1.0.5)
# App  : ghcr.io/gitroomhq/postiz-app:v2.21.7
#
# Layout:
#   - Bundled Postgres + Redis (chart subcharts) — fine for v1.
#   - Local file storage for uploads on a `proxmox-lvm` PVC mounted at /uploads.
#   - JWT_SECRET is sourced from Vault via ESO. The chart's helper-templated
#     Secret name is `<release>-secrets`; we pin `fullnameOverride: postiz` so
#     the Secret resolves to `postiz-secrets`. The chart already mounts that
#     Secret via `envFrom: secretRef: <fullname>-secrets`, so ESO patching the
#     same Secret with `creationPolicy: Merge` injects `JWT_SECRET` into the
#     pod env without forking the chart.
#   - OAuth credentials for Meta/X/LinkedIn etc. are NOT pre-seeded — Postiz
#     stores those in its own DB once the user adds providers via the UI.
# ──────────────────────────────────────────────────────────────────────────────

resource "kubernetes_namespace" "postiz" {
  metadata {
    name = var.namespace
    labels = {
      tier = var.tier
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.postiz.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# /uploads PVC — keeps user-uploaded media across pod restarts.
resource "kubernetes_persistent_volume_claim" "uploads" {
  wait_until_bound = false
  metadata {
    name      = "postiz-uploads"
    namespace = kubernetes_namespace.postiz.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "50Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = {
        storage = var.storage_size
      }
    }
  }
  lifecycle {
    # The autoresizer expands requests.storage up to storage_limit and
    # PVCs can't shrink. Without this, every TF apply tries to revert
    # to the spec value, K8s rejects the shrink, and the PVC ends up
    # in Terminating-but-in-use limbo.
    ignore_changes = [spec[0].resources[0].requests]
  }
}

# ExternalSecret: patches the chart-managed `postiz-secrets` Secret with
# JWT_SECRET pulled from Vault. `creationPolicy: Merge` means ESO will not
# take ownership — it just adds/updates the keys it manages, leaving the
# Helm-owned Secret resource intact. The chart's deployment already wires
# this Secret in via `envFrom: secretRef: postiz-secrets`.
resource "kubernetes_manifest" "external_secret_jwt" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "postiz-jwt-secret"
      namespace = kubernetes_namespace.postiz.metadata[0].name
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name           = "postiz-secrets"
        creationPolicy = "Merge"
      }
      data = [
        {
          secretKey = "JWT_SECRET"
          remoteRef = { key = "instagram-poster", property = "postiz_jwt_secret" }
        },
        {
          secretKey = "FACEBOOK_APP_ID"
          remoteRef = { key = "instagram-poster", property = "facebook_app_id" }
        },
        {
          secretKey = "FACEBOOK_APP_SECRET"
          remoteRef = { key = "instagram-poster", property = "facebook_app_secret" }
        },
        {
          secretKey = "INSTAGRAM_APP_ID"
          remoteRef = { key = "instagram-poster", property = "instagram_app_id" }
        },
        {
          secretKey = "INSTAGRAM_APP_SECRET"
          remoteRef = { key = "instagram-poster", property = "instagram_app_secret" }
        },
      ]
    }
  }
  depends_on = [kubernetes_namespace.postiz]
}

# helm_release.postiz is intentionally NOT managed by Terraform (2026-05-30).
# The release is stuck in pending-install; importing it would force a helm
# upgrade. Left Helm-managed outside TF. The bundled PG/Redis + the postiz
# Deployment/Service it creates therefore aren't TF resources either — only
# the wrapper resources (namespace, PVC, ESO, ingresses, temporal Service,
# nfs backup, backup CronJob) are TF-managed.

# Two ingresses on the same host. /uploads/* must be reachable WITHOUT auth
# so Meta's IG Graph API fetcher can pull the JPEG when Postiz hands it the
# upload URL — when behind Authentik, Meta receives a 302 to the login page
# and rejects with error code 36001 (Postiz mistranslates this as "Invalid
# Instagram image resolution"). Everything else stays behind Authentik.
module "ingress_uploads_public" {
  source       = "../../../../modules/kubernetes/ingress_factory"
  dns_type     = "proxied"
  namespace    = kubernetes_namespace.postiz.metadata[0].name
  name         = "postiz-uploads"
  host         = var.host
  service_name = "postiz"
  port         = 80
  # auth = "none": Meta's IG Graph API fetcher needs unprotected /uploads/* to pull JPEGs (forward-auth 302 causes error 36001).
  auth            = "none"
  ingress_path    = ["/uploads"]
  tls_secret_name = var.tls_secret_name
}

module "ingress" {
  source          = "../../../../modules/kubernetes/ingress_factory"
  dns_type        = "none" # DNS already created by ingress_uploads_public
  namespace       = kubernetes_namespace.postiz.metadata[0].name
  name            = "postiz"
  host            = var.host
  service_name    = "postiz"
  port            = 80
  auth            = "required" # Authentik forward-auth on the UI / API path
  ingress_path    = ["/"]
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Postiz"
    "gethomepage.dev/description"  = "Social media post scheduler"
    "gethomepage.dev/icon"         = "postiz.png"
    "gethomepage.dev/group"        = "Automation"
    "gethomepage.dev/pod-selector" = ""
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Temporal — Postiz's scheduled-post backend. The Deployment is intentionally
# NOT managed here: it was removed from the cluster and postiz currently runs
# without it (immediate posting works; scheduled posting does not). Only the
# Service below is retained/adopted so the in-cluster `temporal:7233` name
# still resolves. To restore scheduled posting, re-add a temporalio/auto-setup
# Deployment (see git history: removed 2026-05-30 during postiz state adoption).
# ──────────────────────────────────────────────────────────────────────────────

resource "kubernetes_service" "temporal" {
  metadata {
    name      = "temporal"
    namespace = kubernetes_namespace.postiz.metadata[0].name
  }
  spec {
    selector = { app = "temporal" }
    port {
      name        = "grpc"
      port        = 7233
      target_port = 7233
    }
  }
}

# ──────────────────────────────────────────────────────────────────────────────
# Backup CronJob — nightly pg_dump of the bundled postiz-postgresql to NFS.
#
# The bundled PostgreSQL StatefulSet uses local-path storage on the K8s node
# OS disk (chart default), which is NOT covered by Layer 1 (LVM thin
# snapshots) or Layer 2 (sda file backup) of the 3-2-1 pipeline. A pg_dump
# CronJob writing to /srv/nfs/postiz-backup/ closes the gap: dumps land on
# Proxmox host NFS → covered by inotify-driven offsite sync to Synology.
# Three databases are dumped: postiz (app data), temporal (workflow engine),
# temporal_visibility (workflow search). Bitnami chart-default credentials
# are used — same creds the Postiz pod itself uses, scoped to the postiz
# namespace via ClusterIP-only Services.
# ──────────────────────────────────────────────────────────────────────────────

module "nfs_backup_host" {
  source     = "../../../../modules/kubernetes/nfs_volume"
  name       = "postiz-backup-host"
  namespace  = kubernetes_namespace.postiz.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/postiz-backup"
}

resource "kubernetes_cron_job_v1" "postgres_backup" {
  metadata {
    name      = "postiz-postgres-backup"
    namespace = kubernetes_namespace.postiz.metadata[0].name
    labels    = { app = "postiz", component = "backup" }
  }
  spec {
    schedule                      = "0 3 * * *"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 5
    job_template {
      metadata {}
      spec {
        backoff_limit              = 1
        ttl_seconds_after_finished = 86400
        template {
          metadata {
            labels = { app = "postiz", component = "backup" }
          }
          spec {
            restart_policy = "OnFailure"
            container {
              name = "backup"
              # Same image/pattern as dbaas/postgresql-backup: official postgres
              # client tools + apt-installed curl for the Pushgateway push. The
              # bitnamilegacy/postgresql variant is stripped (no curl/wget/python),
              # so the metric push silently failed there.
              image   = "docker.io/library/postgres:16.4-bullseye"
              command = ["/bin/bash", "-c"]
              args = [
                <<-EOT
                set -uo pipefail
                apt-get update -qq && apt-get install -yqq curl >/dev/null 2>&1 || true
                TIMESTAMP=$(date +%Y%m%d_%H%M)
                BACKUP_DIR=/backup
                STATUS=0
                for db in postiz; do
                  echo "Dumping $db..."
                  if PGPASSWORD=postiz-password pg_dump -h postiz-postgresql -U postiz \
                       --format=custom --compress=6 \
                       --file="$BACKUP_DIR/$db-$TIMESTAMP.dump" \
                       "$db"; then
                    echo "  OK: $db ($(du -h "$BACKUP_DIR/$db-$TIMESTAMP.dump" | cut -f1))"
                  else
                    echo "  FAIL: $db" >&2
                    STATUS=1
                  fi
                done
                find "$BACKUP_DIR" -name '*.dump' -mtime +30 -delete 2>/dev/null || true
                {
                  echo "backup_last_run_timestamp $(date +%s)"
                  echo "backup_last_status $STATUS"
                  [ "$STATUS" -eq 0 ] && echo "backup_last_success_timestamp $(date +%s)"
                } | curl -sf --connect-timeout 5 --max-time 10 --data-binary @- \
                  "http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/postiz-postgres-backup" || true
                exit $STATUS
                EOT
              ]
              volume_mount {
                name       = "backup"
                mount_path = "/backup"
              }
              resources {
                requests = { cpu = "10m", memory = "64Mi" }
                limits   = { memory = "256Mi" }
              }
            }
            volume {
              name = "backup"
              persistent_volume_claim {
                claim_name = module.nfs_backup_host.claim_name
              }
            }
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
  }
}
