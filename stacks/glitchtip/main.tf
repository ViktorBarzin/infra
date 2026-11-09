# GlitchTip: errors and crashes from the Sentry SDKs (ADR-0041,
# docs/architecture/glitchtip.md).
#
# One Deployment runs the web server with the embedded background worker
# (GLITCHTIP_EMBED_WORKER, the shape GlitchTip's own Helm chart uses since 6.x;
# there is no separate Celery or beat process any more). Two init containers
# run first: the schema migrations, then the allauth SocialApp upsert for the
# Authentik OIDC application in authentik.tf.
#
# Browsers send through the Ingest path `/_t/x/` on each app's own host, a
# Traefik route in stacks/rybbit that strips `/_t/x` and forwards to the
# `glitchtip` Service below, so GlitchTip sees /api/<project_id>/envelope/.

variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "postgresql_host" { type = string }

locals {
  namespace = "glitchtip"
  host      = "glitchtip.viktorbarzin.me"
  image     = "docker.io/glitchtip/glitchtip:6.2.6"

  oidc_client_id   = "glitchtip"
  oidc_provider_id = "authentik"

  labels = {
    app = "glitchtip"
  }

  # Shared by the web container and both init containers.
  env = {
    GLITCHTIP_DOMAIN = "https://${local.host}"
    # The settings module in the ConfigMap below: glitchtip.settings plus the
    # two proxy settings GlitchTip does not read from the environment.
    DJANGO_SETTINGS_MODULE = "glitchtip.settings_proxy"
    # Ingest requests arrive with the app's own Host (tv.viktorbarzin.me and
    # so on) through the Ingest path, and in-cluster clients use the Service
    # name. POD_IP is appended by GlitchTip itself, for the kubelet probes.
    ALLOWED_HOSTS        = ".viktorbarzin.me,glitchtip,glitchtip.glitchtip,glitchtip.glitchtip.svc,glitchtip.glitchtip.svc.cluster.local"
    CSRF_TRUSTED_ORIGINS = "https://${local.host}"

    # No Valkey: an empty VALKEY_URL moves the task queue, cache and sessions
    # to Postgres, which GlitchTip supports. The shared Redis would need this
    # namespace in stacks/redis redis_client_namespaces, and error volume is
    # small enough for the database.
    VALKEY_URL = ""
    # Migrations run in the init container, so the web process skips them.
    SKIP_INIT              = "true"
    GLITCHTIP_EMBED_WORKER = "true"
    # Pool and worker sizes for a small install on the shared primary
    # (max_connections 200). GlitchTip's defaults are 20 and 20.
    DATABASE_POOL_MAX_SIZE = "10"
    VTASKS_CONCURRENCY     = "8"
    # Granian recycles a worker above this RSS (MiB). Its own default is half
    # the memory limit but at least 1024, which equals the 1Gi limit below, so
    # the recycle would never come before the OOM kill.
    GRANIAN_WORKERS_MAX_RSS = "512"

    # Retention: GlitchTip's default, written out so a change upstream does
    # not change ours. Events, transactions, logs, uptime and files inherit it.
    GLITCHTIP_RETENTION_DAYS = "90"

    # Local sign-up is closed once the first account exists. OIDC sign-up
    # stays open, because Authentik admits only Home Server Admins
    # (authentik.tf), so a new admin gets an account on first login.
    ENABLE_USER_REGISTRATION             = "false"
    ENABLE_SOCIAL_APPS_USER_REGISTRATION = "true"
    ENABLE_ORGANIZATION_CREATION         = "false"

    DEFAULT_FROM_EMAIL = "info@viktorbarzin.me"

    OIDC_CLIENT_ID  = local.oidc_client_id
    OIDC_PROVIDER   = local.oidc_provider_id
    OIDC_SERVER_URL = "https://authentik.viktorbarzin.me/application/o/glitchtip/.well-known/openid-configuration"
  }

  secret_env = {
    SECRET_KEY         = { secret = "glitchtip-secrets", key = "secret_key", optional = false }
    OIDC_CLIENT_SECRET = { secret = "glitchtip-secrets", key = "oidc_client_secret", optional = false }
    DATABASE_URL       = { secret = "glitchtip-db-creds", key = "DATABASE_URL", optional = false }
    # Optional: without it GlitchTip sends no mail (alerts can still go to
    # webhooks). Format: smtp+tls://<user>:<password>@mail.viktorbarzin.me:587
    # with @ in the user written as %40.
    EMAIL_URL = { secret = "glitchtip-secrets", key = "email_url", optional = true }
  }

  settings_proxy_py = <<-PY
    # Mounted by stacks/glitchtip. GlitchTip runs behind Traefik, which
    # terminates TLS, and reads neither setting from the environment. Without
    # them Django sees every request as http: allauth builds an http OIDC
    # redirect_uri, which Authentik rejects.
    from glitchtip.settings import *  # noqa: F401,F403

    SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https")
    ACCOUNT_DEFAULT_HTTP_PROTOCOL = "https"
  PY

  configure_oidc_py = <<-PY
    # Upserts the allauth SocialApp for the Authentik OIDC application from
    # the environment, so the client secret in Vault is the only copy that
    # has to be kept. Runs on every pod start, after the migrations.
    import os
    import sys

    # Run as `python /config/configure_oidc.py`, so the script's directory is
    # on sys.path, not the image's working directory with the glitchtip package.
    sys.path.insert(0, "/code")

    import django

    django.setup()

    from allauth.socialaccount.models import SocialApp

    provider_id = os.environ["OIDC_PROVIDER"]
    app = SocialApp.objects.filter(
        provider="openid_connect", provider_id=provider_id
    ).first() or SocialApp(provider="openid_connect", provider_id=provider_id)
    app.name = "Authentik"
    app.client_id = os.environ["OIDC_CLIENT_ID"]
    app.secret = os.environ["OIDC_CLIENT_SECRET"]
    app.key = ""
    app.settings = {
        "server_url": os.environ["OIDC_SERVER_URL"],
        "oauth_pkce_enabled": True,
    }
    app.save()
    print(f"SocialApp openid_connect/{provider_id} configured (id {app.pk})")
  PY
}

resource "kubernetes_namespace" "glitchtip" {
  metadata {
    name = local.namespace
    labels = {
      tier = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# Vault KV secret/glitchtip: secret_key, oidc_client_secret, and optionally
# email_url.
resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "glitchtip-secrets"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "glitchtip-secrets"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
        }
      }
      dataFrom = [{
        extract = {
          key = "glitchtip"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.glitchtip]
}

# Database credentials from the Vault static role pg-glitchtip
# (stacks/vault app_db_roles.tf), rotated weekly in its Tuesday slot. The
# db-rotation-watcher force-syncs this ExternalSecret and Reloader restarts
# the pod.
resource "kubernetes_manifest" "db_external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "glitchtip-db-creds"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "glitchtip-db-creds"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
          data = {
            DATABASE_URL = "postgres://glitchtip:{{ .password }}@${var.postgresql_host}:5432/glitchtip"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/pg-glitchtip"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.glitchtip]
}

# Kyverno ClusterPolicy `sync-tls-secret` clones the wildcard TLS secret into
# every namespace, so there is no setup_tls_secret module here.

resource "kubernetes_config_map" "config" {
  metadata {
    name      = "glitchtip-config"
    namespace = kubernetes_namespace.glitchtip.metadata[0].name
  }
  data = {
    "settings_proxy.py" = local.settings_proxy_py
    "configure_oidc.py" = local.configure_oidc_py
  }
}

# Uploaded files: source maps, ProGuard mappings and native debug files, which
# GlitchTip stores under /code/uploads (FileField upload_to "uploads/...",
# relative to the image's working directory). Encrypted class because source
# maps carry first-party source code. No backup CronJob: these are build
# artifacts that CI uploads again with each release, and the events
# themselves are in Postgres, which the nightly per-database pg_dump covers.
resource "kubernetes_persistent_volume_claim" "uploads" {
  wait_until_bound = false
  metadata {
    name      = "glitchtip-uploads-encrypted"
    namespace = kubernetes_namespace.glitchtip.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "10Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted"
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
  lifecycle {
    # The autoresizer expands requests.storage up to storage_limit and PVCs
    # can't shrink; without this every apply tries to revert the size.
    ignore_changes = [spec[0].resources[0].requests]
  }
}

resource "kubernetes_deployment" "glitchtip" {
  metadata {
    name      = "glitchtip"
    namespace = kubernetes_namespace.glitchtip.metadata[0].name
    labels = merge(local.labels, {
      tier = local.tiers.aux
    })
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    # One replica: the embedded worker's scheduler takes a lock, so more would
    # work, but the RWO uploads volume allows one pod.
    replicas = 1
    strategy {
      # RWO uploads volume: a rolling update would deadlock on the new pod
      # waiting for a volume the old pod still holds.
      type = "Recreate"
    }
    selector {
      match_labels = local.labels
    }
    template {
      metadata {
        labels = local.labels
        annotations = {
          "dependency.kyverno.io/wait-for" = "postgresql.dbaas:5432"
          # Restart when the mounted settings or the OIDC script change.
          "checksum/config" = sha256(jsonencode(kubernetes_config_map.config.data))
        }
      }
      spec {
        # The image runs as user `app` (uid 5000); fs_group lets it write the
        # uploads volume.
        security_context {
          run_as_user     = 5000
          run_as_group    = 5000
          fs_group        = 5000
          run_as_non_root = true
        }

        init_container {
          name    = "migrate"
          image   = local.image
          command = ["./bin/run-migrate.sh"]
          dynamic "env" {
            for_each = local.env
            content {
              name  = env.key
              value = env.value
            }
          }
          dynamic "env" {
            for_each = local.secret_env
            content {
              name = env.key
              value_from {
                secret_key_ref {
                  name     = env.value.secret
                  key      = env.value.key
                  optional = env.value.optional
                }
              }
            }
          }
          volume_mount {
            name       = "config"
            mount_path = "/code/glitchtip/settings_proxy.py"
            sub_path   = "settings_proxy.py"
            read_only  = true
          }
          resources {
            requests = {
              cpu    = "50m"
              memory = "256Mi"
            }
            limits = {
              memory = "768Mi"
            }
          }
        }

        init_container {
          name    = "oidc-app"
          image   = local.image
          command = ["python", "/config/configure_oidc.py"]
          dynamic "env" {
            for_each = local.env
            content {
              name  = env.key
              value = env.value
            }
          }
          dynamic "env" {
            for_each = local.secret_env
            content {
              name = env.key
              value_from {
                secret_key_ref {
                  name     = env.value.secret
                  key      = env.value.key
                  optional = env.value.optional
                }
              }
            }
          }
          volume_mount {
            name       = "config"
            mount_path = "/code/glitchtip/settings_proxy.py"
            sub_path   = "settings_proxy.py"
            read_only  = true
          }
          volume_mount {
            name       = "config"
            mount_path = "/config"
            read_only  = true
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "192Mi"
            }
            limits = {
              memory = "384Mi"
            }
          }
        }

        container {
          name  = "glitchtip"
          image = local.image

          port {
            name           = "http"
            container_port = 8000
          }
          env {
            name = "POD_IP"
            value_from {
              field_ref {
                field_path = "status.podIP"
              }
            }
          }
          dynamic "env" {
            for_each = local.env
            content {
              name  = env.key
              value = env.value
            }
          }
          dynamic "env" {
            for_each = local.secret_env
            content {
              name = env.key
              value_from {
                secret_key_ref {
                  name     = env.value.secret
                  key      = env.value.key
                  optional = env.value.optional
                }
              }
            }
          }
          volume_mount {
            name       = "config"
            mount_path = "/code/glitchtip/settings_proxy.py"
            sub_path   = "settings_proxy.py"
            read_only  = true
          }
          volume_mount {
            name       = "uploads"
            mount_path = "/code/uploads"
          }
          # Probes as in GlitchTip's Helm chart.
          liveness_probe {
            http_get {
              path = "/_health/"
              port = 8000
            }
            initial_delay_seconds = 10
            period_seconds        = 30
            timeout_seconds       = 3
            failure_threshold     = 5
          }
          readiness_probe {
            http_get {
              path = "/_health/"
              port = 8000
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 2
            failure_threshold     = 10
          }
          # No measurements yet: the chart's defaults (256Mi request, 512Mi
          # limit) are for the web pod alone, and the embedded worker runs in
          # the same process here. Right-size with krr after a few weeks.
          resources {
            requests = {
              cpu    = "50m"
              memory = "384Mi"
            }
            limits = {
              memory = "1Gi"
            }
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.config.metadata[0].name
          }
        }
        volume {
          name = "uploads"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.uploads.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,                                                  # KYVERNO_LIFECYCLE_V1
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
    ]
  }
  depends_on = [
    kubernetes_manifest.external_secret,
    kubernetes_manifest.db_external_secret,
  ]
}

# The Ingest path route in stacks/rybbit forwards /_t/x/ here.
resource "kubernetes_service" "glitchtip" {
  metadata {
    name      = "glitchtip"
    namespace = kubernetes_namespace.glitchtip.metadata[0].name
    labels    = local.labels
  }
  spec {
    selector = local.labels
    port {
      name        = "http"
      port        = 80
      target_port = 8000
    }
  }
}

module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # Forward auth would 302 sentry-cli and glitchtip-cli, which upload source
  # maps and ProGuard mappings from CI with GlitchTip API tokens.
  # auth = "app": GlitchTip's own login gates the dashboard. Sign-in is through the Authentik OIDC application in authentik.tf (Home Server Admins only), and local sign-up is closed.
  auth            = "app"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.glitchtip.metadata[0].name
  name            = "glitchtip"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "GlitchTip"
    "gethomepage.dev/description"  = "Error and crash tracking (Sentry-compatible)"
    "gethomepage.dev/icon"         = "glitchtip.png"
    "gethomepage.dev/group"        = "Development & CI"
    "gethomepage.dev/pod-selector" = ""
  }
}
