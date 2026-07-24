# =============================================================================
# stremio — self-hosted Stremio streaming server with NVENC transcoding (infra#80)
# =============================================================================
# Custom image ghcr.io/viktorbarzin/stremio-nvenc (repo ~/code/stremio-nvenc):
# tsaridas layout re-based to Debian/glibc + jellyfin-ffmpeg 4.4.1-4 NVENC,
# bundled web client + nginx HTTP basic-auth on ALL paths INCLUDING the
# /{infohash} torrent path (no open torrent gateway). Behind Traefik (TLS
# terminated at the edge), the pod serves plain HTTP on 8080.
#
# GPU: one time-slice of the shared T4 + a reserved 1500 MiB gpumem seat (ADR-0016).
# The seat fits under the 14000 advertised budget once portal-stt is decommissioned
# (13600 - 1500 + 1500 = 13600). Torrenting stays enabled as a debrid backup
# (Sofia egress; egress left open — no restrictive NetworkPolicy — for BitTorrent).
#
# Effectively stateless: addons/library live in the Stremio account (api.strem.io),
# not on disk. /data is an emptyDir (transcode/torrent scratch); an
# ephemeral-storage limit bounds cache growth (llama-swap hardening pattern).
#
# HITL: agent drafts; operator presence-claims the T4 + applies from the MAIN
# checkout (git-crypt) — never a worktree.
# =============================================================================

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

locals {
  namespace = "stremio"
  labels    = { app = "stremio" }
  image     = "ghcr.io/viktorbarzin/stremio-nvenc:latest"
}

resource "kubernetes_namespace" "stremio" {
  metadata {
    name = local.namespace
    labels = {
      tier               = local.tiers.gpu
      "istio-injection"  = "disabled"
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# TLS: the wildcard `tls-secret` is auto-synced into every namespace by the
# Kyverno `sync-tls-secret` ClusterPolicy (match: all Namespaces), so this stack
# does NOT call setup_tls_secret (which reads a per-stack secrets/fullchain.pem
# this stack doesn't ship). The ingress references tls_secret_name directly.

# basic-auth USERNAME/PASSWORD from Vault secret/stremio -> k8s Secret stremio-secrets.
resource "kubernetes_manifest" "external_secret" {
  field_manager { force_conflicts = true }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "stremio-secrets"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { name = "vault-kv", kind = "ClusterSecretStore" }
      target          = { name = "stremio-secrets" }
      data = [
        { secretKey = "webui_user", remoteRef = { key = "stremio", property = "webui_user" } },
        { secretKey = "webui_password", remoteRef = { key = "stremio", property = "webui_password" } },
      ]
    }
  }
  depends_on = [kubernetes_namespace.stremio]
}

resource "kubernetes_deployment" "stremio" {
  metadata {
    name      = "stremio"
    namespace = local.namespace
    labels    = merge(local.labels, { tier = local.tiers.gpu })
  }
  spec {
    replicas = 1
    # Recreate: only one pod should hold the T4 slice + emptyDir cache at a time.
    strategy { type = "Recreate" }
    selector { match_labels = { app = "stremio" } }
    template {
      metadata { labels = { app = "stremio" } }
      spec {
        node_selector = { "nvidia.com/gpu.present" = "true" }
        toleration {
          key      = "nvidia.com/gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }
        priority_class_name = "gpu-workload"
        image_pull_secrets { name = "ghcr-credentials" } # Kyverno-synced (allowlist in stacks/kyverno)

        container {
          name              = "stremio"
          image             = local.image
          image_pull_policy = "Always"

          port {
            container_port = 8080
            name           = "http"
          }

          # basic-auth creds (entrypoint generates htpasswd from these).
          env {
            name = "USERNAME"
            value_from {
              secret_key_ref {
                name = "stremio-secrets"
                key  = "webui_user"
              }
            }
          }
          env {
            name = "PASSWORD"
            value_from {
              secret_key_ref {
                name = "stremio-secrets"
                key  = "webui_password"
              }
            }
          }
          # Web client points its streaming-server URL at the browser origin
          # (same-origin https://stremio.viktorbarzin.me) so basic-auth carries.
          env {
            name  = "AUTO_SERVER_URL"
            value = "1"
          }
          env {
            name  = "NO_CORS"
            value = "1"
          }
          env {
            name  = "APP_PATH"
            value = "/data"
          }
          # NVENC needs the `video` driver capability; the operator injects only
          # compute,utility by default (compute covers the nvenc-linux probe's CUDA
          # context, utility covers nvidia-smi). Scoped narrowly rather than `all`
          # — no broader caps are needed. NVIDIA_VISIBLE_DEVICES is intentionally
          # left to the device plugin (injected from the nvidia.com/gpu=1 request,
          # like every sibling GPU stack) — hardcoding `all` would override the
          # per-container time-slice isolation.
          env {
            name  = "NVIDIA_DRIVER_CAPABILITIES"
            value = "compute,utility,video"
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          # /manifest.json is served statically by nginx WITHOUT basic-auth, so
          # it's a valid probe target (every other path 401s pre-auth).
          startup_probe {
            http_get {
              path = "/manifest.json"
              port = 8080
            }
            period_seconds    = 5
            failure_threshold = 24 # ~2 min for nginx + server.js to come up
          }
          readiness_probe {
            http_get {
              path = "/manifest.json"
              port = 8080
            }
            period_seconds    = 15
            failure_threshold = 4
          }
          liveness_probe {
            http_get {
              path = "/manifest.json"
              port = 8080
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            failure_threshold     = 5
          }

          resources {
            # Burstable QoS is intentional here (not the requests==limits rule for
            # stable GPU workloads): idle RSS is ~62Mi and only spikes during an
            # active transcode, so a lean 512Mi request avoids reserving 2Gi on the
            # memory-contended GPU node1 (code-j3tx packing hazard) while the 2Gi
            # limit gives transcode headroom.
            requests = {
              cpu                 = "100m"
              memory              = "512Mi"
              "ephemeral-storage" = "2Gi"
            }
            limits = {
              memory              = "2Gi"
              "ephemeral-storage" = "20Gi" # bounds emptyDir + writable-layer cache growth
              "nvidia.com/gpu"    = "1"    # ONE time-slice (operator advertises 100), NOT the whole card
              # GPU VRAM budget (ADR-0016): NVENC transcode sessions (~1.2-1.5 GiB).
              "viktorbarzin.me/gpumem" = "1500"
            }
          }
        }

        volume {
          name = "data"
          empty_dir { size_limit = "20Gi" }
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
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — Woodpecker/Keel manage the tag
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
  }
  depends_on = [kubernetes_manifest.external_secret]
}

resource "kubernetes_service" "stremio" {
  metadata {
    name      = "stremio"
    namespace = local.namespace
    labels    = local.labels
  }
  spec {
    selector = { app = "stremio" }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }
}

module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": the stremio-nvenc image serves its OWN HTTP basic-auth (nginx)
  # on ALL paths incl. the /{infohash} torrent path. Authentik forward-auth breaks
  # Stremio's browser client (can't follow the OAuth 302), and basic-auth is the
  # proven-working gate for the media/HLS/torrent paths. Non-proxied (bypasses
  # Cloudflare's CDN-video ToS); CrowdSec nftables covers the origin IP. See infra#80.
  auth            = "none"
  dns_type        = "non-proxied"
  namespace       = kubernetes_namespace.stremio.metadata[0].name
  name            = "stremio"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Stremio"
    "gethomepage.dev/description"  = "Self-hosted Stremio (NVENC transcode)"
    "gethomepage.dev/icon"         = "stremio.png"
    "gethomepage.dev/group"        = "Media & Entertainment"
    "gethomepage.dev/pod-selector" = ""
  }
}

# =============================================================================
# cinemeta proxy — cinemeta.viktorbarzin.me (infra#80 follow-up, 2026-07-22)
# =============================================================================
# Viktor's Meta-managed Mac has an endpoint firewall (uberAgent) that blocks
# *.strem.io, so the Stremio web client's Cinemeta catalog/meta fetches
# ("Popular", "Featured", ...) fail there — the Stremio home board's rows never
# load. This tiny nginx re-serves Cinemeta through cinemeta.viktorbarzin.me (a
# host the firewall allows): it fetches v3-cinemeta.strem.io itself and follows
# Cinemeta's catalog 307 to cinemeta-catalogs.strem.io server-side, so the
# browser never requests a strem.io hostname. Config + rationale in
# cinemeta-nginx.conf. The account's official com.linvo.cinemeta was removed in
# favour of this proxy (installed at #1 via addonCollectionSet, id
# com.viktorbarzin.cinemeta-proxy), so ALL devices now use it.
#
# In-cluster (behind Traefik) rather than a CF Worker specifically so the host
# resolves BOTH publicly (CF `*` wildcard -> tunnel -> Traefik) AND internally
# (Technitium ingress-DNS-sync -> apex -> Traefik) — a Worker only exists at the
# edge, leaving home-LAN (Technitium) clients on NXDOMAIN. Also draws no CF
# Worker quota (cinemeta is carved out of the outage-failover wildcard Worker in
# stacks/cloudflared). Public catalog data only — no auth, no user data.
resource "kubernetes_config_map" "cinemeta_proxy_nginx" {
  metadata {
    name      = "cinemeta-proxy-nginx"
    namespace = local.namespace
  }
  data = {
    "default.conf" = file("${path.module}/cinemeta-nginx.conf")
  }
}

resource "kubernetes_deployment" "cinemeta_proxy" {
  metadata {
    name      = "cinemeta-proxy"
    namespace = local.namespace
    labels    = { app = "cinemeta-proxy", tier = local.tiers.gpu }
  }
  spec {
    # 2 replicas: this is on the critical path for Cinemeta on EVERY device now,
    # so survive a single node drain/crash. Stateless pure proxy.
    replicas = 2
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = 1
        max_unavailable = 0 # a new pod is Ready before an old one leaves
      }
    }
    selector { match_labels = { app = "cinemeta-proxy" } }
    template {
      metadata {
        labels = { app = "cinemeta-proxy" }
        # Roll the pods whenever the nginx config changes (ConfigMap updates don't
        # restart mounted-file consumers on their own).
        annotations = { "checksum/config" = sha256(file("${path.module}/cinemeta-nginx.conf")) }
      }
      spec {
        # NOT GPU-pinned (plain nginx). Spread the 2 replicas across nodes.
        affinity {
          pod_anti_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 100
              pod_affinity_term {
                topology_key = "kubernetes.io/hostname"
                label_selector {
                  match_labels = { app = "cinemeta-proxy" }
                }
              }
            }
          }
        }
        container {
          name              = "nginx"
          image             = "nginx:1.27"
          image_pull_policy = "IfNotPresent"

          port {
            container_port = 8080
            name           = "http"
          }

          volume_mount {
            name       = "nginx-conf"
            mount_path = "/etc/nginx/conf.d/default.conf"
            sub_path   = "default.conf"
            read_only  = true
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            period_seconds    = 10
            failure_threshold = 3
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 10
            period_seconds        = 30
            failure_threshold     = 3
          }

          resources {
            # Burstable, tiny — nginx idle RSS ~10-20Mi; it only shuttles small
            # JSON. Explicit so the tier-gpu LimitRange defaults don't inflate it.
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }
        }

        volume {
          name = "nginx-conf"
          config_map {
            name = kubernetes_config_map.cinemeta_proxy_nginx.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "cinemeta_proxy" {
  metadata {
    name      = "cinemeta-proxy"
    namespace = local.namespace
    labels    = { app = "cinemeta-proxy" }
  }
  spec {
    selector = { app = "cinemeta-proxy" }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }
}

module "cinemeta_ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": Cinemeta catalog/meta is PUBLIC data (no user data). The
  # Stremio web client fetches it client-side via stremio-core (WASM), which can
  # neither complete Authentik's OAuth 302 nor solve an Anubis PoW challenge — so
  # both are disabled. The proxy exposes only Cinemeta's read-only JSON.
  auth             = "none"
  anti_ai_scraping = false # stremio-core fetch can't solve PoW; it's an API host
  # Proxied: rides the CF `*` wildcard publicly AND gets an internal Technitium
  # record from the ingress-DNS-sync, so cinemeta.viktorbarzin.me resolves on
  # both the public internet and the home LAN. (Carved out of the outage-failover
  # Worker in stacks/cloudflared so it draws no Worker quota.)
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.stremio.metadata[0].name
  name            = "cinemeta"
  service_name    = kubernetes_service.cinemeta_proxy.metadata[0].name
  tls_secret_name = var.tls_secret_name
}
