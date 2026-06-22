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
  # If you bump this image, also bump `playwright==X.Y.Z` in callers'
  # requirements (currently f1-stream, snapshot-harvester) and re-run the
  # connect smoke test. Image ships chromium under /ms-playwright/.
  image = "mcr.microsoft.com/playwright:v1.48.0-noble"
  # Python image for the snapshot-harvester CronJob and the snapshot-server
  # sidecar (the latter just runs a 60-line stdlib HTTP server).
  python_image = "mcr.microsoft.com/playwright/python:v1.48.0-noble"
  snapshot_dir = "/profile/snapshots"
}

# --- Namespace ---

resource "kubernetes_namespace" "chrome_service" {
  metadata {
    name = local.namespace
    labels = {
      "istio-injection"                       = "disabled"
      tier                                    = local.tiers.aux
      "chrome-service.viktorbarzin.me/server" = "true"
      "keel.sh/enrolled"                      = "true"
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
    apiVersion = "external-secrets.io/v1"
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
          name = "chrome-service"
          # Real Google Chrome (Playwright base + google-chrome-stable) for
          # proprietary H.264/AAC codecs — see files/chrome/Dockerfile. The
          # snapshot sidecars still use local.python_image (playwright minor
          # pin) and connect_over_cdp; verified compatible with this Chrome.
          image             = "ghcr.io/viktorbarzin/chrome-service-browser:latest"
          image_pull_policy = "IfNotPresent"

          # Direct chromium launch (NOT `playwright launch-server`). Reason:
          # launch-server creates ephemeral browser contexts per `connect()`
          # call, so cookies/localStorage never persist to the PVC — the
          # `/profile` mount only ever held npm cache + fontconfig.
          # Replaced 2026-06-04 with a CDP+persistent-profile model so the
          # warm browser (where Viktor logs in via noVNC) keeps cookies, and
          # the hourly snapshot-harvester CronJob can dump them via the
          # CDP endpoint. Callers migrate `chromium.connect()` →
          # `chromium.connect_over_cdp()` (see f1-stream's playback_verifier).
          #
          # --remote-debugging-port=9222          : TCP CDP (vs default pipe).
          # --remote-debugging-address=0.0.0.0   : bind on all pod IFs;
          #                                        NetworkPolicy is the gate.
          # --remote-allow-origins=*             : Chrome 111+ requires for
          #                                        non-loopback CDP origins.
          # --user-data-dir=/profile/chromium-data: persistent profile on
          #                                        the encrypted PVC.
          command = ["bash", "-c"]
          args = [
            <<-EOT
            set -e
            # Real Google Chrome (proprietary H.264/AAC codecs) baked into the
            # chrome-service-browser image at a fixed path — so H.264 video
            # (Reels) plays in the noVNC view. The bundled Chromium under
            # /ms-playwright lacks those codecs (MEDIA_ERR_SRC_NOT_SUPPORTED).
            CHROMIUM=/opt/google/chrome/chrome
            if [ ! -x "$CHROMIUM" ]; then
              echo "ERROR: google-chrome not found at $CHROMIUM (wrong image?)" >&2
              exit 1
            fi
            echo "[chrome-service] using browser: $($CHROMIUM --version 2>/dev/null || echo "$CHROMIUM")"

            # -listen tcp enables localhost:6099 so the noVNC sidecar can
            # attach over the pod's shared network ns (Ubuntu 24.04
            # defaults Xvfb to -nolisten tcp). -ac disables X access
            # control; safe because Xvfb only listens on the pod's lo.
            Xvfb :99 -screen 0 1280x720x24 -listen tcp -ac &
            sleep 1

            mkdir -p /profile/chromium-data ${local.snapshot_dir}

            # Why a bridge?
            # Stock Chrome binaries silently ignore --remote-debugging-address
            # (the flag is gated by a build-time switch most distributions don't
            # set), so CDP always binds 127.0.0.1:<port> regardless of what we
            # pass. The K8s liveness/readiness probe + cluster callers reach
            # the pod via its pod-IP, never localhost.
            # Fix: chromium listens on 127.0.0.1:9223 (hidden internal port),
            # cdp_bridge.py listens on 0.0.0.0:9222 (the public CDP port) and
            # transparently forwards. K8s Service, probes, NetworkPolicy all
            # stay on 9222 — no caller-side changes needed.
            # (Microsoft playwright image ships python3 but not socat, so the
            # bridge is a tiny stdlib script — see files/cdp_bridge.py.)
            python3 /scripts/cdp_bridge.py &
            BRIDGE_PID=$!
            trap "kill $BRIDGE_PID 2>/dev/null" EXIT

            exec "$CHROMIUM" \
              --remote-debugging-port=9223 \
              --remote-allow-origins=* \
              --user-data-dir=/profile/chromium-data \
              --no-sandbox \
              --no-first-run \
              --no-default-browser-check \
              --disable-blink-features=AutomationControlled \
              --disable-features=IsolateOrigins,site-per-process \
              --autoplay-policy=no-user-gesture-required \
              --disable-dev-shm-usage \
              --password-store=basic \
              --use-mock-keychain \
              --window-position=0,0 \
              --window-size=1280,720 \
              about:blank
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

          port {
            name           = "cdp"
            container_port = 9222
            protocol       = "TCP"
          }

          # Chrome's CDP endpoint serves /json/version once it's bound;
          # TCP-open is enough for readiness.
          liveness_probe {
            tcp_socket { port = 9222 }
            initial_delay_seconds = 30
            period_seconds        = 30
            failure_threshold     = 3
          }
          readiness_probe {
            tcp_socket { port = 9222 }
            initial_delay_seconds = 10
            period_seconds        = 10
          }
          startup_probe {
            tcp_socket { port = 9222 }
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
          # /scripts/cdp_bridge.py provides the 0.0.0.0:9222 → 127.0.0.1:9223
          # TCP forwarder (see entrypoint comment above for why).
          volume_mount {
            name       = "scripts"
            mount_path = "/scripts"
            read_only  = true
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
        # ingress at chrome.viktorbarzin.me. CDP port 9222 (the new
        # Playwright endpoint) stays internal-only.
        container {
          name = "novnc"
          # Phase 3 cutover 2026-05-07 — Forgejo registry consolidation.
          image             = "ghcr.io/viktorbarzin/chrome-service-novnc:latest"
          image_pull_policy = "IfNotPresent"
          # Cap RLIMIT_NOFILE before the entrypoint runs. Containerd grants pods
          # nofile=2^31; x11vnc sweeps the whole fd table on each client connect,
          # so every VNC connection hangs on "Connecting" until it times out
          # (fd-sweep bug, same as android-emulator). entrypoint.sh now also sets
          # this, but the image is :latest/IfNotPresent so a rebuilt entrypoint
          # isn't guaranteed to be pulled — this wrapper applies the cap
          # deterministically on every rollout off the cached image.
          command = ["bash", "-c", "ulimit -n 65536; exec /entrypoint.sh"]
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

        # snapshot-server sidecar — serves the hourly storage-state.json
        # snapshot (written by the snapshot-harvester CronJob to the same
        # PVC) over an HTTP endpoint, bearer-gated by PW_TOKEN. Mounted
        # behind Traefik at chrome.viktorbarzin.me/api/snapshot with
        # auth=none; the bearer check inside this server is the gate.
        # Source: files/snapshot_server.py — 60 lines, stdlib only.
        container {
          name              = "snapshot-server"
          image             = local.python_image
          image_pull_policy = "IfNotPresent"
          command           = ["python3", "/scripts/snapshot_server.py"]

          env {
            name = "PW_TOKEN"
            value_from {
              secret_key_ref {
                name = "chrome-service-secrets"
                key  = "api_bearer_token"
              }
            }
          }
          env {
            name  = "SNAPSHOT_PATH"
            value = "${local.snapshot_dir}/storage-state.json"
          }
          env {
            name  = "PORT"
            value = "8088"
          }

          port {
            name           = "snap"
            container_port = 8088
            protocol       = "TCP"
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8088
            }
            initial_delay_seconds = 5
            period_seconds        = 30
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8088
            }
            initial_delay_seconds = 2
            period_seconds        = 10
          }

          volume_mount {
            name       = "profile"
            mount_path = "/profile"
            read_only  = true
          }
          volume_mount {
            name       = "scripts"
            mount_path = "/scripts"
            read_only  = true
          }

          resources {
            requests = { cpu = "5m", memory = "32Mi" }
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
        volume {
          name = "scripts"
          config_map {
            name         = kubernetes_config_map_v1.snapshot_scripts.metadata[0].name
            default_mode = "0555"
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
      # container[0]=chrome-service (MS Playwright, pinned via local.image) and
      # container[1]=novnc (ghcr:latest, ADR-0002 #29) are BOTH TF-managed now.
      # container[0].image was previously KEEL_IGNORE'd here; that let a stray
      # clobber to the novnc image stick (chromium-not-found crashloop 2026-06-16)
      # because TF could not revert the ignored field. Removed so TF re-asserts the
      # pinned image. Keel is inert (keel.sh/policy=never) and no deploy step touches these.
      # NOTE: the LIVE pod's container order had drifted to [novnc, chrome-service,
      # snapshot] vs this file's [chrome-service, novnc, snapshot]; a TF apply reorders
      # them to match here (harmless), so `containers[0]` differs between live and TF
      # until the next apply lands — don't be alarmed reading it back mid-reconcile.
      spec[0].template[0].spec[0].init_container[0].image,
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
  }
}

# --- ConfigMap: sidecar + harvester scripts ---
resource "kubernetes_config_map_v1" "snapshot_scripts" {
  metadata {
    name      = "snapshot-scripts"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
    labels    = local.labels
  }
  data = {
    "snapshot_server.py"    = file("${path.module}/files/snapshot_server.py")
    "snapshot_harvester.py" = file("${path.module}/files/snapshot_harvester.py")
    # Tiny TCP forwarder used by chrome-service container to bridge
    # 0.0.0.0:9222 → 127.0.0.1:9223 (Chromium silently ignores
    # --remote-debugging-address on stock builds; see cdp_bridge.py).
    "cdp_bridge.py" = file("${path.module}/files/cdp_bridge.py")
  }
}

# --- Services ---
# CDP endpoint (internal only, gated by NetworkPolicy). 2026-06-04: switched
# from Playwright WS (:3000) to direct chromium CDP (:9222) so the persistent
# user-data-dir actually persists cookies; callers use `connect_over_cdp()`.
resource "kubernetes_service" "chrome_service" {
  metadata {
    name      = "chrome-service"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
    labels    = local.labels
  }

  spec {
    selector = local.labels
    port {
      name        = "cdp"
      port        = 9222
      target_port = 9222
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

# Snapshot-server endpoint (bearer-gated, exposed via ingress sub-path
# chrome.viktorbarzin.me/api/snapshot — auth=none at the ingress layer
# because the bearer check happens inside snapshot_server.py).
resource "kubernetes_service" "chrome_snapshot" {
  metadata {
    name      = "chrome-snapshot"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
    labels    = local.labels
  }

  spec {
    selector = local.labels
    port {
      name        = "snap"
      port        = 8088
      target_port = 8088
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

# Second ingress on the same host (chrome.viktorbarzin.me) carving out
# /api/snapshot to the snapshot-server sidecar. Path-level carve-out
# pattern — see CLAUDE.md "For path-level carve-outs (e.g. wrongmove has
# `/` behind Anubis but `/api` direct), declare a second ingress_factory
# with `ingress_path = ["/<path>"]` pointing at the bare backend service."
module "ingress_snapshot" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": bearer-token gated inside snapshot-server.py; Authentik
  # forward-auth would require an OIDC cookie that the dev-box refresh
  # timer can't replay.
  auth            = "none"
  dns_type        = "none" # DNS already created by module.ingress
  namespace       = kubernetes_namespace.chrome_service.metadata[0].name
  name            = "chrome-snapshot"
  host            = "chrome"
  service_name    = kubernetes_service.chrome_snapshot.metadata[0].name
  port            = 8088
  ingress_path    = ["/api/snapshot"]
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled" = "false"
  }
}

# --- NetworkPolicy: scoped ingress.
# - TCP/9222 (Chromium CDP): only from labelled client namespaces.
# - TCP/6080 (noVNC HTTP+WS): only from the traefik namespace (public path
#   is chrome.viktorbarzin.me → Traefik → sidecar; Authentik forward-auth
#   gates external access at the Traefik layer).
# - TCP/8088 (snapshot-server): only from the traefik namespace
#   (chrome.viktorbarzin.me/api/snapshot → Traefik → sidecar; bearer token
#   is the gate inside snapshot-server.py).
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
      # Also admit chrome-service's own namespace (the snapshot-harvester
      # CronJob runs here and needs to reach the CDP endpoint).
      from {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "chrome-service"
          }
        }
      }
      ports {
        port     = "9222"
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
      ports {
        port     = "8088"
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

# --- Snapshot harvester CronJob: hourly storage_state() dump via CDP ---
# Connects to the live chrome-service CDP endpoint, accesses the
# persistent default browser context (where Viktor's noVNC logins live),
# and writes cookies + localStorage to /profile/snapshots/storage-state.json
# (atomic rename). The snapshot-server sidecar reads from the same file.
resource "kubernetes_cron_job_v1" "chrome_service_snapshot_harvester" {
  metadata {
    name      = "chrome-service-snapshot-harvester"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
  }
  spec {
    concurrency_policy            = "Replace"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 1
    # Hourly, offset from the backup CronJob (which runs at :47 every 6h)
    # so they don't fight for the encrypted PVC at the same minute.
    schedule                  = "23 * * * *"
    starting_deadline_seconds = 60
    job_template {
      metadata {}
      spec {
        backoff_limit              = 2
        ttl_seconds_after_finished = 300
        template {
          metadata {}
          spec {
            # PVC is RWO — colocate with the chrome-service pod.
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
              name              = "harvester"
              image             = local.python_image
              image_pull_policy = "IfNotPresent"
              # The Microsoft playwright/python image ships only browsers +
              # Python — the `playwright` pip package itself is NOT installed
              # (it's meant for CI that brings its own requirements). We
              # install at startup, caching to the PVC so subsequent runs
              # are near-instant.
              command = ["bash", "-c"]
              args = [
                <<-EOT
                set -e
                export PIP_CACHE_DIR=/profile/.cache/pip
                export PIP_DISABLE_PIP_VERSION_CHECK=1
                python3 -c 'import playwright' 2>/dev/null \
                  || pip install --quiet --no-warn-script-location playwright==1.48.0
                exec python3 /scripts/snapshot_harvester.py
                EOT
              ]
              env {
                name  = "CDP_URL"
                value = "http://chrome-service.chrome-service.svc.cluster.local:9222"
              }
              env {
                name  = "SNAPSHOT_DIR"
                value = local.snapshot_dir
              }
              # Don't try to download browsers — connect_over_cdp doesn't
              # need them locally.
              env {
                name  = "PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD"
                value = "1"
              }
              volume_mount {
                name       = "profile"
                mount_path = "/profile"
              }
              volume_mount {
                name       = "scripts"
                mount_path = "/scripts"
                read_only  = true
              }
              resources {
                requests = { cpu = "20m", memory = "128Mi" }
                limits   = { memory = "512Mi" }
              }
            }
            volume {
              name = "profile"
              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim.profile_encrypted.metadata[0].name
              }
            }
            volume {
              name = "scripts"
              config_map {
                name         = kubernetes_config_map_v1.snapshot_scripts.metadata[0].name
                default_mode = "0555"
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
