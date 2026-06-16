# ──────────────────────────────────────────────────────────────────────────────
# Postiz — social media post scheduler (Instagram Stories + others).
#
# Chart: oci://ghcr.io/gitroomhq/postiz-helmchart/charts/postiz (v1.0.5)
# App  : ghcr.io/gitroomhq/postiz-app:v2.21.7
#
# Layout (2026-06-16 — migrated off the bundled subcharts onto shared infra):
#   - Postgres: shared CNPG cluster (pg-cluster-rw.dbaas). The `postiz` role
#     uses a STATIC password in Vault KV secret/postiz (DB-engine rotation for
#     pg-postiz was removed — see stacks/vault), so the chart carries
#     DATABASE_URL directly with no ESO-merge race / no Reloader requirement.
#   - Redis: shared standalone redis-master.redis on logical DB index 11.
#   - Local file storage for uploads on a `proxmox-lvm` PVC mounted at /uploads.
#   - All secret env (DATABASE_URL, JWT_SECRET, Meta OAuth app creds) is sourced
#     from Vault and rendered into the chart's `secrets:` block. fullnameOverride
#     pins the Secret/Service to `postiz` so the instagram-poster pipeline's
#     internal URL (http://postiz.postiz.svc.cluster.local) keeps resolving.
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

# Vault-sourced secret env for the chart's `secrets:` block. The values are
# static, so injecting them straight into the chart-managed Secret avoids the
# ESO-merge-vs-helm-reset race and the Reloader requirement.
#   secret/postiz           -> database_url (shared CNPG; postiz role, static pw)
#   secret/instagram-poster -> JWT + Facebook/Instagram OAuth app creds (the same
#                              Vault keys the old ESO used; shared with the
#                              instagram-poster pipeline that drives the public API)
data "vault_kv_secret_v2" "postiz" {
  mount = "secret"
  name  = "postiz"
}

data "vault_kv_secret_v2" "instagram_poster" {
  mount = "secret"
  name  = "instagram-poster"
}

# Postiz Helm release — Terraform-managed (2026-06-16), replacing the stuck
# out-of-band pending-install release. Bundled PG/Redis subcharts disabled; the
# app runs against shared CNPG + shared Redis. Chart name is `postiz-app`.
resource "helm_release" "postiz" {
  name       = "postiz"
  namespace  = kubernetes_namespace.postiz.metadata[0].name
  repository = "oci://ghcr.io/gitroomhq/postiz-helmchart/charts"
  chart      = "postiz-app"
  version    = var.chart_version
  # No atomic/auto-rollback on first install so a bad boot is debuggable, not
  # silently rolled back. wait=false so the apply doesn't block on pod readiness.
  atomic = false
  wait   = false
  timeout = 600

  values = [yamlencode({
    fullnameOverride = "postiz"
    replicaCount     = 1
    image = {
      repository = "ghcr.io/gitroomhq/postiz-app"
      tag        = var.image_tag
      pullPolicy = "IfNotPresent"
    }
    service = {
      type = "ClusterIP"
      port = 80
    }
    # Bundled subcharts OFF — use shared CNPG + shared Redis instead.
    postgresql = { enabled = false }
    redis      = { enabled = false }

    resources = {
      requests = { cpu = "100m", memory = "2Gi" }
      limits   = { memory = "3Gi" }
    }

    # Non-secret env (chart renders these into the postiz-config ConfigMap).
    env = {
      MAIN_URL                     = "https://postiz.viktorbarzin.me"
      FRONTEND_URL                 = "https://postiz.viktorbarzin.me"
      NEXT_PUBLIC_BACKEND_URL      = "https://postiz.viktorbarzin.me/api"
      BACKEND_INTERNAL_URL         = "http://localhost:3000"
      TEMPORAL_ADDRESS             = "temporal:7233"
      STORAGE_PROVIDER             = "local"
      UPLOAD_DIRECTORY             = "/uploads"
      NEXT_PUBLIC_UPLOAD_DIRECTORY = "/uploads"
      IS_GENERAL                   = "true"
      NX_ADD_PLUGINS               = "false"
      DISABLE_REGISTRATION         = "true"
      # Only Instagram + Facebook are enabled (shared Meta app creds); every
      # other provider stays disabled until its own OAuth app is registered.
      DISABLED_PROVIDERS = "x,linkedin,reddit,threads,youtube,tiktok,pinterest,dribbble,slack,discord,mastodon,bluesky,lemmy,warpcast,vk,beehiiv,telegram,wordpress,nostr,farcaster"
    }

    # Secret env (chart renders these into the postiz-secrets Secret, envFrom).
    secrets = {
      DATABASE_URL         = data.vault_kv_secret_v2.postiz.data["database_url"]
      REDIS_URL            = "redis://redis-master.redis.svc.cluster.local:6379/11"
      JWT_SECRET           = data.vault_kv_secret_v2.instagram_poster.data["postiz_jwt_secret"]
      FACEBOOK_APP_ID      = data.vault_kv_secret_v2.instagram_poster.data["facebook_app_id"]
      FACEBOOK_APP_SECRET  = data.vault_kv_secret_v2.instagram_poster.data["facebook_app_secret"]
      INSTAGRAM_APP_ID     = data.vault_kv_secret_v2.instagram_poster.data["instagram_app_id"]
      INSTAGRAM_APP_SECRET = data.vault_kv_secret_v2.instagram_poster.data["instagram_app_secret"]
    }

    # Persist uploaded media on the existing proxmox-lvm PVC.
    extraVolumes = [{
      name                  = "uploads-volume"
      persistentVolumeClaim = { claimName = kubernetes_persistent_volume_claim.uploads.metadata[0].name }
    }]
    extraVolumeMounts = [{
      name      = "uploads-volume"
      mountPath = "/uploads"
    }]
  })]

  depends_on = [kubernetes_namespace.postiz, module.tls_secret]
}

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
