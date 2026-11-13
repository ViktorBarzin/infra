# Cloud's reconciler (src/entrypoints/reconciler.ts in the cloud repo, image
# ghcr.io/viktorbarzin/cloud-reconciler, the Dockerfile's `reconciler`
# target). It claims reconcile jobs from the `cloud` database and applies each
# Project with OpenTofu, as service account cloud-reconciler (main.tf; its
# rights are in access_rules.tf). Env and credential files are in
# deploy_rules.tf; docs/architecture/cloud.md has the credentials table and
# docs/runbooks/cloud.md the operations.

locals {
  cloud_reconciler_labels = { app = local.cloud_reconciler }
  cloud_reconciler_mounts = { for f in local.cloud_reconciler_files : f.mount => f.secret... }
  # One volume per Secret, each mounted as a directory (no subPath), so the
  # kubelet refreshes the files when ESO writes a rotated value.
  cloud_reconciler_volumes = {
    for mount, secrets in local.cloud_reconciler_mounts : secrets[0] => {
      mount = mount
      items = [for f in local.cloud_reconciler_files : { key = f.secret_key, path = f.key } if f.secret == secrets[0]]
    }
  }
  # metrics port: the image's METRICS_PORT default.
  cloud_reconciler_metrics_port = 9090
  # A job runs init, plan and apply, each up to RECONCILE_STEP_TIMEOUT_SECONDS
  # (1200), then the rollout check (180). On SIGTERM the reconciler finishes
  # the running job, so a Reloader restart, a pod delete or a CI rollout never
  # cuts an apply short. A drain or eviction with a shorter grace period does
  # (the automated node upgrade drains with --grace-period=300): the job stays
  # `running` until RECONCILE_STALE_SECONDS, is requeued and resumes from the
  # OpenTofu state.
  cloud_reconciler_grace_seconds = 3 * 1200 + 180
}

# CLOUD_STATE_URL and POSTGRES_PROVISIONER_PASSWORD from the Vault database
# engine (static roles pg-cloud-state and pg-cloud-provisioner, rotated on
# Tuesdays at 10:17; stacks/vault cloud.tf). The db-rotation-watcher
# force-syncs vault-database ExternalSecrets after a rotation.
resource "kubernetes_manifest" "reconciler_postgres" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "${local.cloud_reconciler}-postgres"
      namespace = module.console.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "${local.cloud_reconciler}-postgres"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
          data = {
            # The pg backend and the state-schema drop take a URL; the worker
            # decodes the password from it (decodeURIComponent).
            "state-url"            = "postgres://cloud_state:{{ .state_password | urlquery }}@${var.postgresql_host}:5432/cloud_state?sslmode=require"
            "provisioner-password" = "{{ .provisioner_password }}"
          }
        }
      }
      data = [
        { secretKey = "state_password", remoteRef = { key = "static-creds/pg-cloud-state", property = "password" } },
        { secretKey = "provisioner_password", remoteRef = { key = "static-creds/pg-cloud-provisioner", property = "password" } },
      ]
    }
  }
  depends_on = [module.console]
}

# REGISTRY_TOKEN: the read:packages pull token in secret/cloud/system
# (ghcr_pull_token, written by stacks/authentik cloud-apps.tf), which the
# reconciler copies into each Project's pull secret.
resource "kubernetes_manifest" "reconciler_registry" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "${local.cloud_reconciler}-registry"
      namespace = module.console.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "${local.cloud_reconciler}-registry"
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
        }
      }
      data = [
        { secretKey = "token", remoteRef = { key = "cloud/system", property = "ghcr_pull_token" } },
      ]
    }
  }
  depends_on = [module.console]
}

# M5: GITHUB_DISPATCH_TOKEN, GITHUB_OWNER_READ_TOKEN, FORGEJO_READ_TOKEN,
# FORGEJO_ADMIN_TOKEN and SECRETS_PRIVATE_KEY from secret/cloud/system
# (local.cloud_reconciler_system_keys in deploy_rules.tf). The tokens do not
# exist until Viktor makes them (docs/runbooks/cloud.md, "Turn on builds"):
# dataFrom extract reads whatever the secret holds, and the template renders
# a missing key as an empty file, which the reconciler treats as unset. A
# `data` entry per key would fail the whole sync while one key is missing.
resource "kubernetes_manifest" "reconciler_system" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = local.cloud_reconciler_system_secret
      namespace = module.console.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = local.cloud_reconciler_system_secret
        template = {
          metadata = {
            annotations = {
              "reloader.stakater.com/match" = "true"
            }
          }
          data = local.cloud_reconciler_system_template
        }
      }
      dataFrom = [{ extract = { key = "cloud/system" } }]
    }
  }
  depends_on = [module.console]
}

resource "kubernetes_deployment" "reconciler" {
  # CI owns rollouts (CI_SETS_IMAGE); the first apply may come before the
  # first image.
  wait_for_rollout = false

  metadata {
    name      = local.cloud_reconciler
    namespace = module.console.namespace
    labels    = merge(local.cloud_reconciler_labels, { tier = local.tiers.aux })
    annotations = {
      # A rotated cloud_state or cloud_provisioner password, pull token or
      # secret/cloud/system key restarts the pod, which finishes its running
      # job first. The Postgres and registry files are also read again on
      # every job. cloud-db-creds is left out, as in the
      # console: the pool reads the password file on every new connection.
      "secret.reloader.stakater.com/reload" = join(",", local.cloud_reconciler_reload)
    }
  }

  spec {
    # One worker: cloud_provisioner's CONNECTION LIMIT 5 fits one reconciler
    # (stacks/dbaas cloud_postgres.tf), and Recreate never runs two.
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = local.cloud_reconciler_labels
    }

    template {
      metadata {
        labels = local.cloud_reconciler_labels
      }

      spec {
        service_account_name = local.cloud_reconciler_sa
        # The API token for Kubernetes (OpenTofu's kubernetes provider,
        # TakenHosts, the rollout check) and for the Vault login as role
        # cloud-reconciler.
        automount_service_account_token  = true
        termination_grace_period_seconds = local.cloud_reconciler_grace_seconds

        image_pull_secrets {
          name = "ghcr-credentials"
        }

        security_context {
          run_as_non_root = true
          run_as_user     = 10001
          run_as_group    = 10001
          fs_group        = 10001
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name  = "reconciler"
          image = "ghcr.io/viktorbarzin/cloud-reconciler:${var.image_tag}"

          port {
            name           = "metrics"
            container_port = local.cloud_reconciler_metrics_port
          }

          dynamic "env" {
            for_each = local.cloud_reconciler_env
            content {
              name  = env.value.name
              value = env.value.value
            }
          }

          dynamic "volume_mount" {
            for_each = local.cloud_reconciler_volumes
            content {
              name       = volume_mount.key
              mount_path = volume_mount.value.mount
              read_only  = true
            }
          }
          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            capabilities {
              drop = ["ALL"]
            }
          }

          # No probes: the work loop has no health endpoint, and /metrics
          # answers even while a job runs for minutes. A crash restarts the
          # pod; a hang shows as CloudReconcileQueueStuck.

          # Estimate, not measured: OpenTofu with the kubernetes, vault,
          # postgresql and random providers, parallelism 2.
          resources {
            requests = { cpu = "100m", memory = "384Mi" }
            limits   = { memory = "1Gi" }
          }
        }

        dynamic "volume" {
          for_each = local.cloud_reconciler_volumes
          content {
            name = volume.key
            secret {
              secret_name  = volume.key
              default_mode = "0440"
              dynamic "items" {
                for_each = volume.value.items
                content {
                  key  = items.value.key
                  path = items.value.path
                }
              }
            }
          }
        }
        # Each job's working directory (tofu init, plan files). The
        # providers are linked from the image's read-only mirror, not copied.
        volume {
          name = "tmp"
          empty_dir {
            size_limit = "2Gi"
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["reloader.stakater.com/last-reloaded-from"], # RELOADER_LIFECYCLE_V1
      spec[0].template[0].spec[0].dns_config,                                                  # KYVERNO_LIFECYCLE_V1
      spec[0].template[0].spec[0].container[0].image,                                          # CI_SETS_IMAGE: first-party image, deployed by the cloud repo's CI
    ]
    precondition {
      condition     = local.cloud_database_url == module.console.database_url
      error_message = "The reconciler's DATABASE_URL (local.cloud_database_url) differs from the console's (module.console.database_url)."
    }
  }

  depends_on = [
    kubernetes_manifest.reconciler_postgres,
    kubernetes_manifest.reconciler_registry,
    kubernetes_manifest.reconciler_system,
    kubernetes_cluster_role_binding.cloud_reconciler,
  ]
}

# Only for the scrape: prometheus.io annotations on a Service are what the
# kubernetes-service-endpoints job reads.
resource "kubernetes_service" "reconciler" {
  metadata {
    name      = local.cloud_reconciler
    namespace = module.console.namespace
    labels    = local.cloud_reconciler_labels
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/path"   = "/metrics"
      "prometheus.io/port"   = tostring(local.cloud_reconciler_metrics_port)
    }
  }
  spec {
    type     = "ClusterIP"
    selector = local.cloud_reconciler_labels
    port {
      name        = "metrics"
      port        = local.cloud_reconciler_metrics_port
      target_port = local.cloud_reconciler_metrics_port
    }
  }
}

# Nothing calls the reconciler; only Prometheus reads /metrics.
resource "kubernetes_network_policy_v1" "reconciler" {
  metadata {
    name      = "${local.cloud_reconciler}-ingress"
    namespace = module.console.namespace
  }
  spec {
    pod_selector {
      match_labels = local.cloud_reconciler_labels
    }
    policy_types = ["Ingress"]
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "monitoring"
          }
        }
      }
      ports {
        port     = tostring(local.cloud_reconciler_metrics_port)
        protocol = "TCP"
      }
    }
  }
}
