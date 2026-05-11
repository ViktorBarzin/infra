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
    apiVersion = "external-secrets.io/v1beta1"
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

resource "helm_release" "postiz" {
  namespace        = kubernetes_namespace.postiz.metadata[0].name
  name             = "postiz"
  create_namespace = false
  atomic           = true
  timeout          = 600

  repository = "oci://ghcr.io/gitroomhq/postiz-helmchart/charts"
  chart      = "postiz-app"
  version    = var.chart_version

  values = [yamlencode({
    fullnameOverride = "postiz"

    image = {
      repository = "ghcr.io/gitroomhq/postiz-app"
      tag        = var.image_tag
      pullPolicy = "IfNotPresent"
    }

    service = {
      type = "ClusterIP"
      port = 80 # chart maps Service port 80 -> targetPort http (containerPort 5000)
    }

    # Non-secret env. Note: BACKEND_INTERNAL_URL stays in-pod (Postiz convention).
    env = {
      MAIN_URL                     = "https://postiz.viktorbarzin.me"
      FRONTEND_URL                 = "https://postiz.viktorbarzin.me"
      NEXT_PUBLIC_BACKEND_URL      = "https://postiz.viktorbarzin.me/api"
      BACKEND_INTERNAL_URL         = "http://localhost:3000"
      STORAGE_PROVIDER             = "local"
      UPLOAD_DIRECTORY             = "/uploads"
      NEXT_PUBLIC_UPLOAD_DIRECTORY = "/uploads"
      # Disabled — admin user already created; sign-in only.
      DISABLE_REGISTRATION = "true"
      IS_GENERAL           = "true"
      NX_ADD_PLUGINS       = "false"
      # Postiz uses Temporal for cron/scheduling — bring our own; Helm chart doesn't.
      TEMPORAL_ADDRESS = "temporal:7233"
    }

    # Postiz reads DATABASE_URL/REDIS_URL from this Secret. The chart does
    # NOT auto-wire bundled subcharts — we have to point at the in-namespace
    # PG/Redis Services. ESO patches JWT_SECRET + FACEBOOK_APP_* on top via
    # creationPolicy=Merge from secret/instagram-poster.
    # Subchart auth uses the chart defaults (postiz / postiz-password,
    # postiz-redis-password) — both Services are ClusterIP, only routable
    # from inside the postiz namespace, so the well-known creds are safe.
    secrets = {
      DATABASE_URL = "postgresql://postiz:postiz-password@postiz-postgresql:5432/postiz"
      REDIS_URL    = "redis://default:postiz-redis-password@postiz-redis-master:6379"
      JWT_SECRET   = ""
      # IG-via-Facebook OAuth (Postiz Instagram-Business integration). Empty
      # placeholder; ESO patches the real values from Vault below.
      FACEBOOK_APP_ID     = ""
      FACEBOOK_APP_SECRET = ""
      # IG standalone (Postiz Instagram-Login integration). Uses the modern
      # `instagram_business_*` scopes — does not require the FB Login dance.
      INSTAGRAM_APP_ID     = ""
      INSTAGRAM_APP_SECRET = ""
    }

    # Use our PVC for uploads (overrides the chart's emptyDir default).
    extraVolumes = [{
      name = "uploads-volume"
      persistentVolumeClaim = {
        claimName = kubernetes_persistent_volume_claim.uploads.metadata[0].name
      }
    }]
    extraVolumeMounts = [{
      name      = "uploads-volume"
      mountPath = "/uploads"
    }]

    # Postiz runs frontend (Next 16) + backend (NestJS) + orchestrator
    # (Temporal worker with webpack bundling) in one pod. The orchestrator
    # alone bundles ~3MB JS per task queue, and on cold start it bundles
    # several queues — pushed peak RSS past 2Gi → OOMKill mid-NestJS init.
    resources = {
      requests = {
        cpu    = "100m"
        memory = "512Mi"
      }
      limits = {
        memory = "4Gi"
      }
    }

    # Bundled stateful deps — fine for v1, reconsider promotion to CNPG later.
    # Subchart passwords intentionally left to chart defaults; the bundled
    # PG/Redis Services are ClusterIP and only routable from the postiz
    # namespace, so the credentials never leave the pod network. Promotion to
    # CNPG with Vault-rotated creds is the next step.
    # Bitnami removed bitnami/postgresql + bitnami/redis from DockerHub
    # (Broadcom acquisition, Aug 2025). Older tags moved to bitnamilegacy/*.
    postgresql = {
      enabled = true
      image = {
        registry   = "docker.io"
        repository = "bitnamilegacy/postgresql"
        tag        = "16.4.0-debian-12-r7"
      }
      auth = {
        username = "postiz"
        database = "postiz"
      }
    }

    redis = {
      enabled = true
      image = {
        registry   = "docker.io"
        repository = "bitnamilegacy/redis"
        tag        = "7.4.0-debian-12-r2"
      }
    }
  })]

  depends_on = [
    kubernetes_persistent_volume_claim.uploads,
    kubernetes_manifest.external_secret_jwt,
  ]
}

# Two ingresses on the same host. /uploads/* must be reachable WITHOUT auth
# so Meta's IG Graph API fetcher can pull the JPEG when Postiz hands it the
# upload URL — when behind Authentik, Meta receives a 302 to the login page
# and rejects with error code 36001 (Postiz mistranslates this as "Invalid
# Instagram image resolution"). Everything else stays behind Authentik.
module "ingress_uploads_public" {
  source          = "../../../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.postiz.metadata[0].name
  name            = "postiz-uploads"
  host            = var.host
  service_name    = "postiz"
  port            = 80
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
# Temporal — cron/workflow engine Postiz requires for scheduled posts.
#
# Lightweight single-replica deployment using temporalio/auto-setup, backed
# by the bundled postiz-postgresql (separate `temporal` database). Visibility
# search via Elasticsearch is disabled (ENABLE_ES=false) — Postiz only uses
# the workflow engine, not visibility, so SQL is enough.
#
# Important: temporalio/auto-setup creates schemas in the `temporal` and
# `temporal_visibility` databases on first boot. We pre-create them with an
# init container running psql against postiz-postgresql.
# ──────────────────────────────────────────────────────────────────────────────

resource "kubernetes_deployment" "temporal" {
  metadata {
    name      = "temporal"
    namespace = kubernetes_namespace.postiz.metadata[0].name
    labels = {
      app = "temporal"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = { app = "temporal" }
    }
    template {
      metadata {
        labels = { app = "temporal" }
      }
      spec {
        # Pre-create the two databases Temporal expects on the bundled PG.
        init_container {
          name  = "create-temporal-dbs"
          image = "docker.io/bitnamilegacy/postgresql:16.4.0-debian-12-r7"
          env {
            name  = "PGPASSWORD"
            value = "postiz-password"
          }
          command = ["/bin/bash", "-c"]
          args = [
            <<-EOT
            set -e
            for db in temporal temporal_visibility; do
              psql -h postiz-postgresql -U postiz -d postgres -tc "SELECT 1 FROM pg_database WHERE datname='$db'" | grep -q 1 \
                || psql -h postiz-postgresql -U postiz -d postgres -c "CREATE DATABASE \"$db\""
            done
            EOT
          ]
        }
        container {
          name  = "temporal"
          image = "temporalio/auto-setup:1.28.1"
          port {
            container_port = 7233
            name           = "grpc"
          }
          env {
            name  = "DB"
            value = "postgres12"
          }
          env {
            name  = "DB_PORT"
            value = "5432"
          }
          env {
            name  = "POSTGRES_USER"
            value = "postiz"
          }
          env {
            name  = "POSTGRES_PWD"
            value = "postiz-password"
          }
          env {
            name  = "POSTGRES_SEEDS"
            value = "postiz-postgresql"
          }
          env {
            name  = "DBNAME"
            value = "temporal"
          }
          env {
            name  = "VISIBILITY_DBNAME"
            value = "temporal_visibility"
          }
          env {
            name  = "ENABLE_ES"
            value = "false"
          }
          env {
            name  = "TEMPORAL_NAMESPACE"
            value = "default"
          }
          # NOTE: not setting DYNAMIC_CONFIG_FILE_PATH — that file isn't
          # bundled in temporalio/auto-setup. Defaults are fine for our
          # use (Postiz only needs the workflow engine, not dynamic config).
          resources {
            requests = {
              cpu    = "50m"
              memory = "256Mi"
            }
            limits = {
              memory = "1Gi"
            }
          }
          # Auto-setup runs schema migrations on first boot — give it time.
          startup_probe {
            tcp_socket {
              port = 7233
            }
            failure_threshold     = 30
            period_seconds        = 5
            initial_delay_seconds = 10
          }
          liveness_probe {
            tcp_socket {
              port = 7233
            }
            period_seconds = 30
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
  }
  depends_on = [helm_release.postiz]
}

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

# One-shot Job: remove the two default Text-typed search attributes
# (CustomTextField, CustomStringField) that temporalio/auto-setup ships
# with. Postiz needs to register `organizationId` + `postId`, and SQL
# visibility caps at 3 Text attributes total — without this, Postiz's
# NestJS bootstrap crashes with "cannot have more than 3 search attribute
# of type Text" and the backend never starts.
# Upstream issue: https://github.com/gitroomhq/postiz-app/issues/1504
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
                for db in postiz temporal temporal_visibility; do
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
  depends_on = [helm_release.postiz]
}

resource "kubernetes_job" "temporal_search_attr_cleanup" {
  metadata {
    name      = "temporal-search-attr-cleanup"
    namespace = kubernetes_namespace.postiz.metadata[0].name
  }
  spec {
    backoff_limit              = 30
    ttl_seconds_after_finished = 300
    template {
      metadata {}
      spec {
        restart_policy = "OnFailure"
        container {
          name    = "cleanup"
          image   = "temporalio/auto-setup:1.28.1"
          command = ["/bin/sh", "-c"]
          args = [
            <<-EOT
            set -e
            # Wait for Temporal to be reachable (auto-setup may take 30s).
            for i in $(seq 1 60); do
              if temporal --address temporal:7233 operator search-attribute list >/dev/null 2>&1; then break; fi
              sleep 5
            done
            for attr in CustomTextField CustomStringField; do
              if temporal --address temporal:7233 operator search-attribute list 2>/dev/null | grep -q "$attr"; then
                temporal --address temporal:7233 operator search-attribute remove --name "$attr" --yes
              fi
            done
            EOT
          ]
        }
      }
    }
  }
  wait_for_completion = false
  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
  }
  depends_on = [kubernetes_deployment.temporal]
}
