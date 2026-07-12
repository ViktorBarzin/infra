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
  atomic  = false
  wait    = false
  timeout = 600

  values = [yamlencode({
    fullnameOverride = "postiz"
    # PARKED (2026-06-28), sablier-enrolled (ADR-0022, 2026-07-12): group
    # "postiz" = postiz + temporal + elasticsearch — one visit to the UI wakes
    # the whole chain (ES → temporal → postiz, ~90-180s cold), 3h idle parks
    # it. replicaCount stays 0 = the parked default; sablier owns the live
    # value (a re-apply of this chart while awake re-parks it — next request
    # re-wakes). Labels land via kubernetes_labels.postiz_sablier below (the
    # chart has no deployment-labels surface).
    replicaCount = 0
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
      # request lowered 2Gi->1Gi so the tier-4-aux ns requests.memory quota (3Gi)
      # fits postiz + temporal + the new Elasticsearch; limit stays 3Gi (Burstable).
      requests = { cpu = "100m", memory = "1Gi" }
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

      # Authentik OIDC ("Login with Authentik") — provider/app in authentik.tf.
      # This Postiz version reads only the AUTH/TOKEN/USERINFO URLs + client
      # id/secret (scope is hardcoded openid/profile/email; redirect is fixed to
      # ${FRONTEND_URL}/settings). The NEXT_PUBLIC display name drives the login
      # button label (best-effort: baked at image build, set here in case the
      # image re-injects NEXT_PUBLIC vars at start).
      POSTIZ_GENERIC_OAUTH                  = "true"
      POSTIZ_OAUTH_AUTH_URL                 = "https://authentik.viktorbarzin.me/application/o/authorize/"
      POSTIZ_OAUTH_TOKEN_URL                = "https://authentik.viktorbarzin.me/application/o/token/"
      POSTIZ_OAUTH_USERINFO_URL             = "https://authentik.viktorbarzin.me/application/o/userinfo/"
      POSTIZ_OAUTH_CLIENT_ID                = "postiz"
      NEXT_PUBLIC_POSTIZ_OAUTH_DISPLAY_NAME = "Authentik"
    }

    # Secret env (chart renders these into the postiz-secrets Secret, envFrom).
    secrets = {
      DATABASE_URL               = data.vault_kv_secret_v2.postiz.data["database_url"]
      REDIS_URL                  = "redis://redis-master.redis.svc.cluster.local:6379/11"
      JWT_SECRET                 = data.vault_kv_secret_v2.instagram_poster.data["postiz_jwt_secret"]
      FACEBOOK_APP_ID            = data.vault_kv_secret_v2.instagram_poster.data["facebook_app_id"]
      FACEBOOK_APP_SECRET        = data.vault_kv_secret_v2.instagram_poster.data["facebook_app_secret"]
      INSTAGRAM_APP_ID           = data.vault_kv_secret_v2.instagram_poster.data["instagram_app_id"]
      INSTAGRAM_APP_SECRET       = data.vault_kv_secret_v2.instagram_poster.data["instagram_app_secret"]
      POSTIZ_OAUTH_CLIENT_SECRET = var.oauth_client_secret
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
  source = "../../../../modules/kubernetes/ingress_factory"
  # Scale-to-zero (ADR-0022): one authenticated visit wakes the whole postiz
  # group (ES → temporal → postiz, ~90-180s cold — expect one CF 524 + retry
  # on a cold hit). The /uploads ingress above deliberately carries NO sablier
  # (dead Meta-fetch path; parked = 503 there, same as before enrollment).
  sablier = {
    group = "postiz"
  }
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
# Temporal — Postiz's workflow backend. RESTORED 2026-06-16 (#44). Postiz's
# backend REFUSES to start its HTTP server unless temporal:7233 is reachable at
# boot — so this is required for Postiz to serve ANYTHING (login + the public
# API), not just scheduled posting. Runs temporalio/auto-setup against the shared
# CNPG cluster with the SQL/Postgres visibility store (no Elasticsearch). The
# `temporal` + `temporal_visibility` DBs already exist and are owned by the
# `postiz` role, so SKIP_DB_CREATE=true + the role's static password is enough
# (auto-setup only creates/updates schema, which the DB owner can do; it is NOT
# superuser and must not attempt CREATE DATABASE).
# ──────────────────────────────────────────────────────────────────────────────

# ──────────────────────────────────────────────────────────────────────────────
# Elasticsearch — Temporal's VISIBILITY store (#44). Required: Postiz registers
# >3 custom Text search attributes, which Temporal's Postgres visibility caps at
# 3 ("cannot have more than 3 search attribute of type Text"). Postiz's upstream
# docker-compose uses ES for exactly this reason. Single-node, security off.
# `node.store.allow_mmap=false` avoids the vm.max_map_count bootstrap check so we
# don't need a privileged sysctl init-container (blocked by Kyverno wave-1).
# ──────────────────────────────────────────────────────────────────────────────

resource "kubernetes_persistent_volume_claim" "es" {
  wait_until_bound = false
  metadata {
    name      = "postiz-es-data"
    namespace = kubernetes_namespace.postiz.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "20Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = { storage = "8Gi" }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].resources[0].requests]
  }
}

# Sablier enrollment labels for the Helm-owned postiz Deployment (ADR-0022).
# The postiz-app chart exposes no deployment-labels value, so this field-manager
# patch stamps them post-install; sablier discovers workloads by DEPLOYMENT
# metadata labels. Survives helm upgrades (three-way merge keeps foreign labels;
# this resource re-asserts them on every apply regardless).
resource "kubernetes_labels" "postiz_sablier" {
  api_version = "apps/v1"
  kind        = "Deployment"
  metadata {
    name      = "postiz"
    namespace = kubernetes_namespace.postiz.metadata[0].name
  }
  labels = {
    "sablier.enable" = "true"
    "sablier.group"  = "postiz"
  }
  depends_on = [helm_release.postiz]
}

resource "kubernetes_deployment_v1" "es" {
  metadata {
    name      = "elasticsearch"
    namespace = kubernetes_namespace.postiz.metadata[0].name
    labels = {
      app = "elasticsearch"
      # Scale-to-zero (ADR-0022): parks/wakes with the postiz group — ES only
      # serves temporal's visibility store, nothing else reads it.
      "sablier.enable" = "true"
      "sablier.group"  = "postiz"
    }
  }
  spec {
    # Sablier-managed (group "postiz"). Was always-on at 1 — ~1GiB idle RAM
    # for a parked app; now parks with the group.
    replicas = 1
    selector { match_labels = { app = "elasticsearch" } }
    strategy { type = "Recreate" }
    template {
      metadata { labels = { app = "elasticsearch" } }
      spec {
        security_context { fs_group = 1000 } # ES runs as uid 1000; make the PVC writable
        # proxmox-lvm CSI doesn't honor fsGroup, so the PVC mounts root-owned and
        # ES (uid 1000) can't write its data dir. Chown it via a root init-container
        # (not privileged → passes Kyverno deny-privileged).
        init_container {
          name    = "fix-data-perms"
          image   = "busybox:1.36"
          command = ["sh", "-c", "chown -R 1000:1000 /usr/share/elasticsearch/data"]
          security_context { run_as_user = 0 }
          volume_mount {
            name       = "data"
            mount_path = "/usr/share/elasticsearch/data"
          }
        }
        container {
          name = "elasticsearch"
          # docker.io/ prefix → matches the Kyverno-trusted `docker.io/*` allowlist
          # (Elastic also publishes the official image to Docker Hub). ES 7.17 == Temporal ES_VERSION=v7.
          image = "docker.io/library/elasticsearch:7.17.28"
          env {
            name  = "discovery.type"
            value = "single-node"
          }
          env {
            name  = "xpack.security.enabled"
            value = "false"
          }
          env {
            name  = "node.store.allow_mmap"
            value = "false"
          }
          env {
            name  = "cluster.routing.allocation.disk.threshold_enabled"
            value = "false"
          }
          env {
            name  = "ingest.geoip.downloader.enabled"
            value = "false"
          }
          env {
            name  = "ES_JAVA_OPTS"
            value = "-Xms512m -Xmx512m"
          }
          port {
            name           = "http"
            container_port = 9200
          }
          volume_mount {
            name       = "data"
            mount_path = "/usr/share/elasticsearch/data"
          }
          resources {
            requests = { cpu = "100m", memory = "1Gi" }
            limits   = { memory = "1536Mi" }
          }
          readiness_probe {
            http_get {
              path = "/_cluster/health?local=true"
              port = 9200
            }
            initial_delay_seconds = 20
            period_seconds        = 10
            failure_threshold     = 18
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.es.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      spec[0].replicas,                       # SABLIER_MANAGED_REPLICAS — sablier scales the postiz group (ADR-0022)
    ]
  }
}

resource "kubernetes_service" "es" {
  metadata {
    name      = "elasticsearch"
    namespace = kubernetes_namespace.postiz.metadata[0].name
  }
  spec {
    selector = { app = "elasticsearch" }
    port {
      name        = "http"
      port        = 9200
      target_port = 9200
    }
  }
}

resource "kubernetes_secret" "temporal_db" {
  metadata {
    name      = "temporal-db"
    namespace = kubernetes_namespace.postiz.metadata[0].name
  }
  data = {
    POSTGRES_PWD = data.vault_kv_secret_v2.postiz.data["db_password"]
  }
}

resource "kubernetes_deployment_v1" "temporal" {
  metadata {
    name      = "temporal"
    namespace = kubernetes_namespace.postiz.metadata[0].name
    labels = {
      app = "temporal"
      # Scale-to-zero (ADR-0022): parks/wakes with the postiz group.
      "sablier.enable" = "true"
      "sablier.group"  = "postiz"
    }
  }
  spec {
    replicas = 0 # PARKED default; sablier-managed with the postiz group (ADR-0022)
    selector { match_labels = { app = "temporal" } }
    strategy { type = "Recreate" }
    template {
      metadata { labels = { app = "temporal" } }
      spec {
        container {
          name  = "temporal"
          image = "temporalio/auto-setup:1.28.1"

          env {
            name  = "DB"
            value = "postgres12"
          }
          env {
            name  = "SKIP_DB_CREATE"
            value = "true"
          }
          env {
            name  = "DBNAME"
            value = "temporal"
          }
          # Visibility = Elasticsearch (Postiz needs >3 Text search attributes,
          # which SQL visibility can't hold). Persistence stays on CNPG (DBNAME).
          env {
            name  = "ENABLE_ES"
            value = "true"
          }
          env {
            name  = "ES_SEEDS"
            value = "elasticsearch.postiz.svc.cluster.local"
          }
          env {
            name  = "ES_VERSION"
            value = "v7"
          }
          env {
            name  = "ES_PORT"
            value = "9200"
          }
          env {
            name  = "ES_SCHEME"
            value = "http"
          }
          env {
            name  = "POSTGRES_SEEDS"
            value = "pg-cluster-rw.dbaas.svc.cluster.local"
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
            name = "POSTGRES_PWD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.temporal_db.metadata[0].name
                key  = "POSTGRES_PWD"
              }
            }
          }

          port {
            name           = "grpc"
            container_port = 7233
          }
          resources {
            requests = { cpu = "50m", memory = "256Mi" }
            limits   = { memory = "512Mi" }
          }
          readiness_probe {
            tcp_socket { port = 7233 }
            initial_delay_seconds = 20
            period_seconds        = 10
            failure_threshold     = 12
          }
        }
      }
    }
  }
  depends_on = [kubernetes_deployment_v1.es, kubernetes_service.es]
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      spec[0].replicas,                       # SABLIER_MANAGED_REPLICAS — sablier scales the postiz group (ADR-0022)
    ]
  }
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
