variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }

locals {
  # Created and labelled by stacks/vault, not here. See the removed block below.
  namespace = "plotting-book"
}
# The plotting-book namespace is owned by stacks/vault, NOT here.
#
# It was declared in both places, so both states held the same object
# (kubernetes_namespace.plotting-book here, and
# kubernetes_namespace.user_namespace["plotting-book"] there) and the two took
# turns rewriting its labels on every apply. That is what kept this stack on the
# differing list in code-yizt.
#
# vault owns it because that is where namespace-owners come from: its
# user_namespace resource iterates every namespace-owner in the k8s_users map, and
# it also creates the user-quota ResourceQuota this namespace has carried since
# 2026-02 plus the resource-governance/custom-quota=true label that stops Kyverno
# generating a second, competing quota beside it. Applying THIS stack's version
# stripped that label and moved the drift onto stacks/vault instead of resolving
# it.
#
# The two labels this declaration added and vault's does not are both dead:
#   istio-injection = "disabled"  — no istio is installed on this cluster at all
#                                   (0 namespaces, 0 pods, verified 2026-09-03)
#   keel.sh/enrolled = "true"     — never reached the live namespace, and the
#                                   deployment carries working keel.sh/policy,
#                                   trigger and pollSchedule annotations anyway
# so nothing observable changes by dropping them. If namespace-level keel
# enrollment is ever wanted here, add it to vault's declaration.
#
# Ordering is safe without a depends_on: terragrunt.hcl already declares
# dependency "vault", so the namespace exists before this stack applies.
#
# Transient, delete once applied: detaches the resource from THIS stack's state
# without deleting the namespace. Same pattern as the cloudflare_ruleset detach
# written up in stacks/rybbit/crowdsec_edge.tf.
removed {
  from = kubernetes_namespace.plotting-book
  lifecycle {
    destroy = false
  }
}

resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "plotting-book-secrets"
      namespace = "plotting-book"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "plotting-book-secrets"
      }
      dataFrom = [{
        extract = {
          key = "plotting-book"
        }
      }]
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = local.namespace
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_persistent_volume_claim" "plotting-book-data" {
  metadata {
    name      = "plotting-book-data-proxmox"
    namespace = local.namespace
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = {
        storage = "1Gi"
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

resource "kubernetes_deployment" "plotting-book" {
  metadata {
    name      = "plotting-book"
    namespace = local.namespace
    labels = {
      app  = "plotting-book"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  lifecycle {
    # DRIFT_WORKAROUND: CI pipeline owns image tag (kubectl set image from Woodpecker/GHA). Reviewed 2026-04-18.
    ignore_changes = [
      spec[0].template[0].spec[0].container[0].image,
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"],                    # KYVERNO_LIFECYCLE_V2
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "plotting-book"
      }
    }
    template {
      metadata {
        labels = {
          app = "plotting-book"
        }
      }
      spec {
        # Pull the PRIVATE ghcr image. The ghcr-credentials secret is cloned
        # into this namespace by the Kyverno generate policy in stacks/kyverno
        # (plotting-book is on its ghcr_private_namespaces allowlist).
        image_pull_secrets {
          name = "ghcr-credentials"
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.plotting-book-data.metadata[0].name
          }
        }
        container {
          # Baseline only — CI owns the live tag (GHA in Anca's repo builds
          # ghcr.io/passionprojectsanca/book-plotter:vX.Y.Z, Woodpecker repo 43
          # set-images it; see ignore_changes above). :latest is pushed by the
          # same GHA build, so a from-scratch apply starts on current code.
          # PRIVATE package — pulled via the ghcr-credentials secret below.
          image = "ghcr.io/passionprojectsanca/book-plotter:latest"
          name  = "plotting-book"
          env {
            name = "SESSION_SECRET"
            value_from {
              secret_key_ref {
                name = "plotting-book-secrets"
                key  = "session_secret"
              }
            }
          }
          env {
            name = "GOOGLE_CLIENT_ID"
            value_from {
              secret_key_ref {
                name = "plotting-book-secrets"
                key  = "google_client_id"
              }
            }
          }
          env {
            name = "GOOGLE_CLIENT_SECRET"
            value_from {
              secret_key_ref {
                name = "plotting-book-secrets"
                key  = "google_client_secret"
              }
            }
          }
          env {
            name  = "GOOGLE_CALLBACK_URL"
            value = "https://plotting-book.viktorbarzin.me/api/auth/google/callback"
          }
          env {
            name  = "DB_PATH"
            value = "/data/database.sqlite"
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          port {
            container_port = 3001
          }
          resources {
            requests = {
              memory = "128Mi"
              cpu    = "10m"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "plotting-book" {
  metadata {
    name      = "plotting-book"
    namespace = local.namespace
    labels = {
      "app" = "plotting-book"
    }
  }

  spec {
    selector = {
      app = "plotting-book"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 3001
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  auth            = "required"
  dns_type        = "non-proxied"
  namespace       = local.namespace
  name            = "plotting-book"
  tls_secret_name = var.tls_secret_name

  custom_content_security_policy = "default-src 'self' blob: data:; img-src 'self' data: blob:; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline' 'unsafe-eval' blob:; worker-src 'self' blob:; connect-src 'self' blob: https://accounts.google.com; form-action 'self' https://accounts.google.com; frame-ancestors 'self' *.viktorbarzin.me viktorbarzin.me"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Plotting Book"
    "gethomepage.dev/description"  = "Interactive fiction"
    "gethomepage.dev/icon"         = "mdi-book-open-variant"
    "gethomepage.dev/group"        = "Other"
    "gethomepage.dev/pod-selector" = ""
  }
}

# -----------------------------------------------------------------------------
# Backup — Weekly SQLite backup to NFS
# -----------------------------------------------------------------------------

module "nfs_plotting_book_backup_host" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "plotting-book-backup-host"
  namespace          = local.namespace
  nfs_server         = "192.168.1.127"
  nfs_path           = "/srv/nfs/plotting-book-backup"
  storage_class_name = "nfs-pve"
}

resource "kubernetes_cron_job_v1" "plotting_book_backup" {
  metadata {
    name      = "plotting-book-backup"
    namespace = local.namespace
  }
  spec {
    concurrency_policy            = "Replace"
    failed_jobs_history_limit     = 3
    schedule                      = "0 3 * * 0"
    starting_deadline_seconds     = 10
    successful_jobs_history_limit = 3
    job_template {
      metadata {}
      spec {
        backoff_limit              = 3
        ttl_seconds_after_finished = 10
        template {
          metadata {}
          spec {
            affinity {
              pod_affinity {
                required_during_scheduling_ignored_during_execution {
                  label_selector {
                    match_labels = {
                      app = "plotting-book"
                    }
                  }
                  topology_key = "kubernetes.io/hostname"
                }
              }
            }
            container {
              name  = "plotting-book-backup"
              image = "docker.io/library/alpine"
              command = ["/bin/sh", "-c", <<-EOT
                set -euxo pipefail
                apk add --no-cache sqlite
                now=$(date +"%Y_%m_%d_%H_%M")
                mkdir -p /backup/$now
                sqlite3 /data/database.sqlite ".backup /backup/$now/database.sqlite"
                # Rotate — 30 day retention
                find /backup -maxdepth 1 -mindepth 1 -type d -mtime +30 -exec rm -rf {} +
                echo "Backup complete: $now"
              EOT
              ]
              volume_mount {
                name       = "data"
                mount_path = "/data"
                read_only  = true
              }
              volume_mount {
                name       = "backup"
                mount_path = "/backup"
              }
              resources {
                requests = {
                  memory = "32Mi"
                  cpu    = "10m"
                }
                limits = {
                  memory = "64Mi"
                }
              }
            }
            volume {
              name = "data"
              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim.plotting-book-data.metadata[0].name
              }
            }
            volume {
              name = "backup"
              persistent_volume_claim {
                claim_name = module.nfs_plotting_book_backup_host.claim_name
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

# Sealed Secrets — encrypted secrets safe to commit to git
resource "kubernetes_manifest" "sealed_secrets" {
  for_each = fileset(path.module, "sealed-*.yaml")
  manifest = yamldecode(file("${path.module}/${each.value}"))
}
