# Executor — self-hosted MCP integration hub (executor.sh, UsefulSoftwareCo/executor).
# One catalog of integrations (MCP servers / OpenAPI / GraphQL) + connected accounts;
# agents consume it via the streamable-HTTP /mcp endpoint. v1 client: hermes-agent only.
# Design: docs/plans/2026-07-12-hermes-agent-v2-discord-claude-design.md (§3.5).

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

variable "nfs_server" { type = string }

locals {
  # Fast-moving upstream (multiple releases/week) — pin exactly; Keel is
  # enrolled with a patch-only policy so bumps stay deliberate.
  executor_image = "ghcr.io/rhyssullivan/executor-selfhost:v1.5.33"
}

# --- Namespace ---

resource "kubernetes_namespace" "executor" {
  metadata {
    name = "executor"
    labels = {
      tier               = local.tiers.aux
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.executor.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# --- Secrets (ESO from Vault secret/executor) ---

resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "executor-secrets"
      namespace = kubernetes_namespace.executor.metadata[0].name
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "executor-secrets"
      }
      dataFrom = [{
        extract = {
          key = "executor"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.executor]
}

# --- Storage ---
# /data holds the SQLite DB, the auto-generated master encryption key
# (EXECUTOR_SECRET_KEY) and every connected account's credentials -> encrypted.

resource "kubernetes_persistent_volume_claim" "data_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "executor-data-encrypted"
    namespace = kubernetes_namespace.executor.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
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
    # pvc-autoresizer owns requests.storage growth; K8s rejects shrinks.
    ignore_changes = [spec[0].resources[0].requests]
  }
}

# --- Deployment ---

resource "kubernetes_deployment" "executor" {
  metadata {
    name      = "executor"
    namespace = kubernetes_namespace.executor.metadata[0].name
    labels = {
      app  = "executor"
      tier = local.tiers.aux
    }
    annotations = {
      "keel.sh/policy"       = "patch"
      "keel.sh/trigger"      = "poll"
      "keel.sh/pollSchedule" = "@daily"
    }
  }
  spec {
    strategy {
      type = "Recreate" # RWO volume
    }
    replicas = 1
    selector {
      match_labels = {
        app = "executor"
      }
    }
    template {
      metadata {
        labels = {
          app = "executor"
        }
        annotations = {
          "reloader.stakater.com/search" = "true"
        }
      }
      spec {
        security_context {
          fs_group = 1000
        }
        container {
          name  = "executor"
          image = local.executor_image

          port {
            container_port = 4788
          }

          env {
            name  = "PORT"
            value = "4788"
          }
          env {
            name  = "EXECUTOR_HOST"
            value = "0.0.0.0"
          }
          env {
            name  = "EXECUTOR_DATA_DIR"
            value = "/data"
          }
          env {
            # Must EXACTLY match the browser URL (scheme+host) or better-auth
            # rejects logins with an invalid-origin error.
            name  = "EXECUTOR_WEB_BASE_URL"
            value = "https://executor.viktorbarzin.me"
          }
          env {
            name = "EXECUTOR_BOOTSTRAP_ADMIN_EMAIL"
            value_from {
              secret_key_ref {
                name = "executor-secrets"
                key  = "bootstrap_admin_email"
              }
            }
          }
          env {
            name = "EXECUTOR_BOOTSTRAP_ADMIN_PASSWORD"
            value_from {
              secret_key_ref {
                name = "executor-secrets"
                key  = "bootstrap_admin_password"
              }
            }
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              memory = "1Gi"
            }
          }

          # Health path undocumented upstream — TCP probe is the safe choice.
          readiness_probe {
            tcp_socket {
              port = 4788
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
          liveness_probe {
            tcp_socket {
              port = 4788
            }
            initial_delay_seconds = 20
            period_seconds        = 30
            failure_threshold     = 3
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data_encrypted.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["keel.sh/match-tag"],
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — Keel manages patch-tag updates
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
  }
}

# --- Service ---

resource "kubernetes_service" "executor" {
  metadata {
    name      = "executor"
    namespace = kubernetes_namespace.executor.metadata[0].name
    labels = {
      app = "executor"
    }
  }
  spec {
    selector = {
      app = "executor"
    }
    port {
      port        = 4788
      target_port = 4788
    }
  }
}

# --- NetworkPolicy: lock 4788 to its two legitimate callers ---
# The /mcp endpoint's client-auth story is an execution gate (E1); this policy
# makes the answer non-load-bearing: only Traefik (web UI ingress) and the
# hermes-agent namespace (MCP client) can reach the pod at all.

resource "kubernetes_network_policy" "executor_ingress" {
  metadata {
    name      = "executor-allow-traefik-and-hermes"
    namespace = kubernetes_namespace.executor.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = {
        app = "executor"
      }
    }
    policy_types = ["Ingress"]
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "traefik"
          }
        }
      }
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "hermes-agent"
          }
        }
      }
      ports {
        port     = "4788"
        protocol = "TCP"
      }
    }
  }
}

# --- Ingress (web UI only; /mcp is consumed cluster-internally) ---

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.executor.metadata[0].name
  name            = "executor"
  service_name    = kubernetes_service.executor.metadata[0].name
  port            = 4788
  tls_secret_name = var.tls_secret_name
  # auth = "app": Executor ships its own authentication (better-auth login +
  # sessions; bootstrap admin seeded from Vault). Authentik forward-auth would
  # break its login/origin checks.
  auth = "app"
  # Owner-only admin surface: resolvable everywhere, routable only from home
  # LANs/WG/VPN; pair with the allowlist middleware per ADR-0021.
  dns_type = "internal"
  # The SPA cold-loads ~40-60 chunks in one burst; over the cloudflared path
  # Traefik sees one client IP, so the default 10/50 limiter 429s the tail.
  # Dedicated 100/1000 limiter (SPA cold-load pattern), allowlist gates first.
  skip_default_rate_limit = true
  extra_middlewares       = ["traefik-home-lans-only@kubernetescrd", "traefik-executor-rate-limit@kubernetescrd"]
  external_monitor  = false
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Executor"
    "gethomepage.dev/description"  = "Agent integration hub (MCP proxy)"
    "gethomepage.dev/icon"         = "mdi-connection"
    "gethomepage.dev/group"        = "AI & Data"
    "gethomepage.dev/pod-selector" = ""
  }
}

# --- Backup: nightly SQLite-safe snapshot + key files to PVE NFS ---

resource "kubernetes_cron_job_v1" "executor_backup" {
  metadata {
    name      = "executor-backup"
    namespace = kubernetes_namespace.executor.metadata[0].name
  }
  spec {
    schedule                      = "30 4 * * *"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 2
    job_template {
      metadata {}
      spec {
        backoff_limit = 1
        template {
          metadata {}
          spec {
            restart_policy = "Never"
            container {
              name  = "backup"
              image = "python:3.12-alpine"
              # Pure stdlib (no pip/apk at runtime): sqlite3.backup() is
              # WAL-safe against the live DB; key files copied verbatim.
              command = ["python3", "-c", <<-EOT
                import glob, os, shutil, sqlite3, time
                ts = time.strftime("%Y%m%d-%H%M%S")
                src = "/data/data.db"
                dst = f"/backup/data-{ts}.db"
                con = sqlite3.connect(f"file:{src}?mode=ro", uri=True)
                bck = sqlite3.connect(dst)
                with bck:
                    con.backup(bck)
                bck.close()
                con.close()
                for f in os.listdir("/data"):
                    p = os.path.join("/data", f)
                    if os.path.isfile(p) and not f.startswith("data.db"):
                        shutil.copy2(p, os.path.join("/backup", f))
                snaps = sorted(glob.glob("/backup/data-*.db"))
                for old in snaps[:-14]:
                    os.remove(old)
                print("backup ok:", dst)
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
                  cpu    = "50m"
                  memory = "64Mi"
                }
                limits = {
                  memory = "256Mi"
                }
              }
            }
            volume {
              name = "data"
              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim.data_encrypted.metadata[0].name
              }
            }
            volume {
              name = "backup"
              nfs {
                server = var.nfs_server
                path   = "/srv/nfs/executor-backup"
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
