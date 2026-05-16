variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }

locals {
  namespace = "chrome-service"
  labels = {
    app = "chrome-service"
  }
  # Pin to the same Playwright minor that the Python client requires.
  # If you bump this image, also bump `playwright==X.Y.Z` in the client
  # (currently f1-stream) and re-run the connect smoke test.
  image = "mcr.microsoft.com/playwright:v1.48.0-noble"
}

# --- Namespace ---

resource "kubernetes_namespace" "chrome_service" {
  metadata {
    name = local.namespace
    labels = {
      "istio-injection"                       = "disabled"
      tier                                    = local.tiers.aux
      "chrome-service.viktorbarzin.me/server" = "true"
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# --- Secrets (single-key extract: api_bearer_token) ---

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "chrome-service-secrets"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "chrome-service-secrets"
      }
      dataFrom = [{
        extract = {
          key = "chrome-service"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.chrome_service]
}

# tls-secret for the chrome.viktorbarzin.me ingress is auto-cloned into
# every namespace by Kyverno's `sync-tls-secret` ClusterPolicy — no local
# module call needed.

# --- Encrypted profile PVC ---
# Holds Chromium user data: cookies, localStorage, IndexedDB. Sites we
# drive may set auth tokens or session cookies — encrypted is correct.
resource "kubernetes_persistent_volume_claim" "profile_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "chrome-service-profile-encrypted"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
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
        storage = "2Gi"
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

# --- NFS backup target ---
module "nfs_chrome_service_backup_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "chrome-service-backup-host"
  namespace  = kubernetes_namespace.chrome_service.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/chrome-service-backup"
}

# --- Deployment ---

resource "kubernetes_deployment" "chrome_service" {
  metadata {
    name      = "chrome-service"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
    labels = merge(local.labels, {
      tier = local.tiers.aux
      # Deliberate pin: chrome-service's playwright image MUST match
      # the playwright Python version in f1-stream (see local.image
      # comment above). Opt out of Keel auto-update via this label —
      # the inject-keel-annotations ClusterPolicy excludes workloads
      # selector-matching keel.sh/policy=never.
      "keel.sh/policy" = "never"
    })
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = local.labels
    }
    template {
      metadata {
        labels = local.labels
      }
      spec {
        # The noVNC sidecar pulls from registry.viktorbarzin.me which needs
        # auth. Kyverno's `sync-registry-credentials` ClusterPolicy syncs
        # the secret into every namespace.
        image_pull_secrets {
          name = "registry-credentials"
        }
        security_context {
          run_as_user  = 1000
          run_as_group = 1000
          fs_group     = 1000
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        # Fix profile dir ownership (PVC may have root-owned files from prior run).
        init_container {
          name    = "fix-perms"
          image   = "busybox:1.37"
          command = ["sh", "-c", "chown -R 1000:1000 /profile"]
          security_context {
            run_as_user = 0
          }
          volume_mount {
            name       = "profile"
            mount_path = "/profile"
          }
          resources {
            requests = { memory = "32Mi" }
            limits   = { memory = "64Mi" }
          }
        }

        container {
          name              = "chrome-service"
          image             = local.image
          image_pull_policy = "IfNotPresent"

          # `launch-server` (not `run-server`) lets us pin headed mode +
          # specific args. `run-server` defaults to headless, which the
          # disable-devtool.js Performance detector trips under Playwright
          # (CDP adds latency to console.log; lib detects + redirects).
          # The Microsoft image ships only the browsers, not the playwright
          # npm package itself — `npx -y playwright@<ver>` downloads it on
          # first start (cached under $HOME/.npm via the PVC) and pins to
          # the same minor as the Python client. Bump in lockstep.
          command = ["bash", "-c"]
          args = [
            <<-EOT
            set -e
            # `-listen tcp` enables localhost:6099 so the noVNC sidecar can
            # connect over the pod's shared network namespace (Ubuntu 24.04
            # defaults Xvfb to -nolisten tcp).
            # `-ac` disables X access control so the noVNC sidecar can
            # attach without an MIT-MAGIC-COOKIE; safe because Xvfb only
            # listens on localhost (pod's lo).
            Xvfb :99 -screen 0 1280x720x24 -listen tcp -ac &
            sleep 1
            cat > /tmp/launch.json <<JSON
            {
              "headless": false,
              "port": 3000,
              "host": "0.0.0.0",
              "wsPath": "/$${PW_TOKEN}",
              "args": [
                "--no-sandbox",
                "--disable-blink-features=AutomationControlled",
                "--disable-features=IsolateOrigins,site-per-process",
                "--autoplay-policy=no-user-gesture-required",
                "--disable-dev-shm-usage"
              ]
            }
            JSON
            exec npx -y playwright@1.48.0 launch-server --browser chromium --config /tmp/launch.json
            EOT
          ]

          env {
            name  = "DISPLAY"
            value = ":99"
          }
          env {
            name  = "HOME"
            value = "/profile"
          }
          env {
            name = "PW_TOKEN"
            value_from {
              secret_key_ref {
                name = "chrome-service-secrets"
                key  = "api_bearer_token"
              }
            }
          }

          port {
            name           = "ws"
            container_port = 3000
            protocol       = "TCP"
          }

          # Playwright run-server exposes only the WS endpoint; no /health.
          liveness_probe {
            tcp_socket { port = 3000 }
            initial_delay_seconds = 30
            period_seconds        = 30
            failure_threshold     = 3
          }
          readiness_probe {
            tcp_socket { port = 3000 }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
          startup_probe {
            tcp_socket { port = 3000 }
            period_seconds    = 5
            failure_threshold = 24 # up to 2 minutes
          }

          volume_mount {
            name       = "profile"
            mount_path = "/profile"
          }
          volume_mount {
            name       = "dshm"
            mount_path = "/dev/shm"
          }

          resources {
            requests = {
              cpu    = "200m"
              memory = "1500Mi"
            }
            limits = {
              memory = "2Gi"
            }
          }
        }

        # noVNC sidecar — exposes a live HTML5 view of the headed Chromium
        # session via x11vnc + websockify, gated by the Authentik-protected
        # ingress at chrome.viktorbarzin.me. WS port 3000 (the Playwright
        # endpoint) stays internal-only.
        container {
          name = "novnc"
          # Phase 3 cutover 2026-05-07 — Forgejo registry consolidation.
          image             = "forgejo.viktorbarzin.me/viktor/chrome-service-novnc:v4"
          image_pull_policy = "IfNotPresent"
          port {
            name           = "http"
            container_port = 6080
            protocol       = "TCP"
          }
          # x11vnc connects to the chrome-service container's Xvfb over
          # localhost TCP (shared pod network). Same uid 1000 as chrome
          # container so we can read MIT-MAGIC-COOKIE if Xvfb adds one.
          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { memory = "96Mi" }
          }
        }

        volume {
          name = "profile"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.profile_encrypted.metadata[0].name
          }
        }
        volume {
          name = "dshm"
          empty_dir {
            medium     = "Memory"
            size_limit = "256Mi"
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
    ]
  }
}

# --- Services ---
# WS endpoint (internal only, gated by NetworkPolicy + token).
resource "kubernetes_service" "chrome_service" {
  metadata {
    name      = "chrome-service"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
    labels    = local.labels
  }

  spec {
    selector = local.labels
    port {
      name        = "ws"
      port        = 3000
      target_port = 3000
      protocol    = "TCP"
    }
  }
}

# noVNC view (Authentik-gated, exposed via ingress).
resource "kubernetes_service" "chrome_novnc" {
  metadata {
    name      = "chrome"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
    labels    = local.labels
  }

  spec {
    selector = local.labels
    port {
      name        = "http"
      port        = 80
      target_port = 6080
      protocol    = "TCP"
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.chrome_service.metadata[0].name
  name            = "chrome"
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  # noVNC defaults to /vnc.html — auto-redirect / there.
  ingress_path = ["/"]
  extra_annotations = {
    "gethomepage.dev/enabled"     = "true"
    "gethomepage.dev/name"        = "Chrome Service"
    "gethomepage.dev/description" = "Live noVNC view of headed Chromium"
    "gethomepage.dev/icon"        = "chromium.png"
    "gethomepage.dev/group"       = "Infrastructure"
  }
}

# --- NetworkPolicy: scoped ingress.
# - TCP/3000 (Playwright WS): only from labelled client namespaces.
# - TCP/6080 (noVNC HTTP+WS): only from the traefik namespace, since the
#   public-facing path is `chrome.viktorbarzin.me` ingress → Traefik →
#   sidecar. Authentik forward-auth still gates external access at the
#   Traefik layer.
# The cluster has no default-deny, so this NP only takes effect inside
# chrome-service ns — pods elsewhere remain unaffected.
resource "kubernetes_network_policy_v1" "ws_ingress" {
  metadata {
    name      = "chrome-service-ws-ingress"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
  }
  spec {
    pod_selector {
      match_labels = local.labels
    }
    policy_types = ["Ingress"]
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "chrome-service.viktorbarzin.me/client" = "true"
          }
        }
      }
      # Explicit fallback list — admit f1-stream by name in case the label
      # is removed by accident. Keep this in sync with the labels above.
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "f1-stream"
          }
        }
      }
      ports {
        port     = "3000"
        protocol = "TCP"
      }
    }
    ingress {
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "traefik"
          }
        }
      }
      ports {
        port     = "6080"
        protocol = "TCP"
      }
    }
  }
}

# --- Backup CronJob: tar+gzip the profile every 6h, 30-day retention. ---
resource "kubernetes_cron_job_v1" "chrome_service_backup" {
  metadata {
    name      = "chrome-service-backup"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
  }
  spec {
    concurrency_policy            = "Replace"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 1
    schedule                      = "47 */6 * * *"
    starting_deadline_seconds     = 60
    job_template {
      metadata {}
      spec {
        backoff_limit              = 2
        ttl_seconds_after_finished = 300
        template {
          metadata {}
          spec {
            # PVC is RWO — colocate the backup pod with the chrome-service
            # pod so both can mount the volume on the same node.
            affinity {
              pod_affinity {
                required_during_scheduling_ignored_during_execution {
                  label_selector {
                    match_labels = local.labels
                  }
                  topology_key = "kubernetes.io/hostname"
                }
              }
            }
            container {
              name  = "backup"
              image = "docker.io/library/alpine:3.20"
              command = ["/bin/sh", "-c", <<-EOT
                set -euxo pipefail
                ts=$(date +"%Y_%m_%d_%H")
                tar -czf /backup/$${ts}.tar.gz -C /profile .
                find /backup -maxdepth 1 -type f -name '*.tar.gz' -mtime +30 -delete
                echo "Backup complete: $${ts}.tar.gz"
              EOT
              ]
              volume_mount {
                name       = "profile"
                mount_path = "/profile"
                read_only  = true
              }
              volume_mount {
                name       = "backup"
                mount_path = "/backup"
              }
              resources {
                requests = { cpu = "10m", memory = "32Mi" }
                limits   = { memory = "64Mi" }
              }
            }
            volume {
              name = "profile"
              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim.profile_encrypted.metadata[0].name
              }
            }
            volume {
              name = "backup"
              persistent_volume_claim {
                claim_name = module.nfs_chrome_service_backup_host.claim_name
              }
            }
            restart_policy = "OnFailure"
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
