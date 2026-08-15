variable "tls_secret_name" {
  type      = string
  sensitive = true
}

# Plan-time read: the /mcp bearer token list is rendered straight into the
# Traefik Middleware CRD, so it cannot come from an ESO-created K8s Secret.
data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "repowise"
}

locals {
  app = "repowise"

  # Pinned upstream release. Keel (policy=patch) rolls 0.x.Y forward on its
  # own; a minor bump is a deliberate edit here. Upstream ships roughly every
  # other day at v0.x, and the MCP tool surface agents depend on should not
  # change under them.
  image = "ghcr.io/viktorbarzin/repowise:0.42.0"

  # Do NOT add image_pull_policy here. The cluster-wide Kyverno policy
  # `set-image-pull-policy` forces IfNotPresent on any pinned tag (and Always
  # only for :latest), so setting it produces a plan that never converges —
  # Terraform writes Always, Kyverno mutates it straight back on pod admission.
  # Consequence to know: rebuilding the SAME version tag (a fix to our own
  # Dockerfile) is not picked up by a restart, because the tag is already
  # cached on the node. Move the pod onto the rebuilt content with
  # `kubectl set image ... =<repo>@sha256:<digest>` — image is the
  # Keel-managed field and is ignore_changes here, so that is the sanctioned
  # nudge. A genuine upstream version bump gets a new tag and needs none of this.
  #
  # The uid/gid the image is patched to use (see build-repowise.yml). The
  # workspace volume is chowned to it via fsGroup.
  run_as = 10001

  workspace = "/workspace"
  api_port  = 7337
  web_port  = 3000
  mcp_port  = 7338
}

resource "kubernetes_namespace" "repowise" {
  metadata {
    name = local.app
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

# api_key       — repowise's own bearer, gating /api (and used by the
#                 reconciler to trigger reindexing over loopback)
# forgejo_token — read-only PAT for cloning the Corpus
# kuma_push_url — heartbeat target for the sync monitor
resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "repowise-secrets"
      namespace = local.app
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "repowise-secrets"
      }
      dataFrom = [{
        extract = {
          key = local.app
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.repowise]
}

# No setup_tls_secret module here on purpose. Kyverno's sync-tls-secret policy
# clones `tls-secret` from the kyverno namespace into every namespace with
# synchronize=true, so the ingresses below find it without this stack shipping
# its own git-crypt'd copy of the cert. Matches the recent-stack pattern
# (pages-publish, goldmane-edge-aggregator, chesscom-streak); the ~116 stacks
# that still call the module predate the clone policy.

# The Corpus: 42 git clones plus their derived per-repo SQLite indexes.
#
# Block storage rather than NFS because repowise hard-codes per-repo SQLite in
# workspace mode (create_engine("sqlite+aiosqlite:///...")), and both the API
# and the MCP server write. Ordinary POSIX locking on a block device is the
# safe way to run that; NFS lock semantics with multiple writers is the
# classic corruption path. All writers therefore live in one pod.
#
# Encrypted class to match Forgejo's own posture — this is a decrypted-at-rest
# mirror of the same private source. Rebuildable from git at any time, so it is
# excluded from the offsite backup legs (see scripts/daily-backup.sh).
resource "kubernetes_persistent_volume_claim" "workspace" {
  wait_until_bound = false
  metadata {
    name      = "repowise-workspace"
    namespace = kubernetes_namespace.repowise.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "15%"
      "resize.topolvm.io/increase"      = "50%"
      "resize.topolvm.io/storage_limit" = "60Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted"
    resources {
      requests = {
        # ~383 MiB of clones today; the indexes, git history and LanceDB
        # scratch grow well past that, and the autoresizer takes it to 60Gi.
        storage = "20Gi"
      }
    }
  }
  lifecycle {
    # The autoresizer expands requests.storage up to storage_limit and PVCs
    # can't shrink. Without this, every apply tries to revert to the spec
    # value, K8s rejects the shrink, and the PVC lands in Terminating-but-
    # in-use limbo.
    ignore_changes = [spec[0].resources[0].requests]
  }
}

resource "kubernetes_config_map" "scripts" {
  metadata {
    name      = "repowise-scripts"
    namespace = kubernetes_namespace.repowise.metadata[0].name
  }
  data = {
    "reconcile.py"  = file("${path.module}/files/reconcile.py")
    "mcp_serve.py"  = file("${path.module}/files/mcp_serve.py")
    "cross_repo.py" = file("${path.module}/files/cross_repo.py")
  }
}

# Gateway-level bearer auth for /mcp. repowise's MCP HTTP transport is
# UNAUTHENTICATED — mcp.run(transport="streamable-http") is called with no auth
# wiring, and REPOWISE_API_KEY only silences a log warning there. This
# Middleware is therefore the only credential gate on that path, behind the
# home-LAN allowlist. Per-holder tokens live in Vault as a JSON array so one
# can be revoked without disturbing the others; rotation = update Vault, apply.
resource "kubernetes_manifest" "bearer_middleware" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "Middleware"
    metadata = {
      name      = "bearer-auth"
      namespace = kubernetes_namespace.repowise.metadata[0].name
    }
    spec = {
      plugin = {
        # Inner key must match the static-config key in Traefik
        # experimental.plugins.api-token-middleware.
        api-token-middleware = {
          authenticationHeader   = false
          bearerHeader           = true
          bearerHeaderName       = "Authorization"
          tokens                 = jsondecode(data.vault_kv_secret_v2.secrets.data["bearer_tokens"])
          removeHeadersOnSuccess = true
          authenticationErrorMsg = "Access Denied"
        }
      }
    }
  }
  depends_on = [kubernetes_namespace.repowise]
}

# One pod, four containers, one image. Everything that writes SQLite has to
# share a node with the volume, so co-locating them is a constraint of the
# storage model rather than a packaging preference.
resource "kubernetes_deployment" "repowise" {
  # Every container reads secret keys from repowise-secrets, which ESO creates.
  # Without this the first apply can roll pods before the secret exists and
  # then wait out its rollout timeout on a CreateContainerConfigError.
  depends_on = [kubernetes_manifest.external_secret]

  metadata {
    name      = local.app
    namespace = kubernetes_namespace.repowise.metadata[0].name
    labels = {
      app  = local.app
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
      # Pinned-version image: take patch releases automatically, hold minors
      # for a deliberate bump. NEVER policy=force here — it would roll to
      # whatever tag a poll happens to pick, regardless of semver order.
      "keel.sh/policy"       = "patch"
      "keel.sh/trigger"      = "poll"
      "keel.sh/pollSchedule" = "@every 6h"
    }
  }
  spec {
    replicas = 1
    strategy {
      # RWO volume with a single SQLite writer: the old pod must release the
      # volume before the new one can attach.
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = local.app
      }
    }
    template {
      metadata {
        labels = {
          app = local.app
        }
      }
      spec {
        # Private ghcr package (AGPL: we run it, we do not convey it).
        # Keel also needs this to poll the tag list.
        image_pull_secrets {
          name = "ghcr-credentials"
        }

        # Build the workspace-level layer (co-changes, contracts, system graph,
        # conformance) BEFORE the API starts. The API loads those artefacts into
        # app.state once, during startup, and offers no way to reload them — so
        # building them here is what makes the System Map, Contracts and
        # Co-Changes views show anything at all. The reconciler rebuilds them on
        # disk hourly; the served copy refreshes on the next restart.
        # Takes about a minute over 42 repos and re-indexes nothing.
        init_container {
          name        = "cross-repo"
          image       = local.image
          working_dir = local.workspace
          command     = ["python3", "/opt/repowise/cross_repo.py"]

          env {
            name  = "REPOWISE_WORKSPACE"
            value = local.workspace
          }
          env {
            name  = "REPOWISE_EMBEDDER"
            value = "mock"
          }

          volume_mount {
            name       = "workspace"
            mount_path = local.workspace
          }
          volume_mount {
            name       = "scripts"
            mount_path = "/opt/repowise"
            read_only  = true
          }

          resources {
            requests = {
              memory = "512Mi"
              cpu    = "50m"
            }
            limits = {
              memory = "2Gi"
            }
          }
        }

        security_context {
          run_as_user  = local.run_as
          run_as_group = local.run_as
          fs_group     = local.run_as
          # The volume is large and mostly unchanging; only chown when the
          # root's ownership is actually wrong.
          fs_group_change_policy = "OnRootMismatch"
        }

        volume {
          name = "workspace"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.workspace.metadata[0].name
          }
        }
        volume {
          name = "scripts"
          config_map {
            name         = kubernetes_config_map.scripts.metadata[0].name
            default_mode = "0555"
          }
        }

        # ---------------------------------------------------------------
        # api — the REST surface, and the only thing that runs reindex jobs
        # ---------------------------------------------------------------
        container {
          name        = "api"
          image       = local.image
          working_dir = local.workspace
          command = [
            "uvicorn", "repowise.server.app:create_app",
            "--factory", "--host", "0.0.0.0", "--port", tostring(local.api_port),
          ]

          port {
            name           = "api"
            container_port = local.api_port
          }

          env {
            name  = "REPOWISE_HOST"
            value = "0.0.0.0"
          }
          env {
            # Deterministic index: no embeddings, therefore no semantic search
            # and no third-party API calls. Nothing leaves the homelab.
            name  = "REPOWISE_EMBEDDER"
            value = "mock"
          }
          env {
            name  = "REPOWISE_PARSE_WORKERS"
            value = "4"
          }
          env {
            # Bearer required for every /api request. Peer-based loopback
            # detection means requests arriving via Traefik are always remote,
            # so without this the API would 403 the dashboard entirely.
            name = "REPOWISE_API_KEY"
            value_from {
              secret_key_ref {
                name = "repowise-secrets"
                key  = "api_key"
              }
            }
          }

          volume_mount {
            name       = "workspace"
            mount_path = local.workspace
          }
          volume_mount {
            # The image defaults its primary DB to /data/wiki.db. In workspace
            # mode that holds only a registry, but keeping it on the volume
            # means a restart does not discard it.
            name       = "workspace"
            mount_path = "/data"
            sub_path   = ".repowise-data"
          }

          startup_probe {
            http_get {
              path = "/health"
              port = local.api_port
            }
            # Generous: on a cold volume the app opens an engine per repo.
            failure_threshold = 60
            period_seconds    = 5
          }
          # Deliberately tolerant. Indexing runs in the same asyncio loop as the
          # HTTP server, and a CPU-bound graph phase (betweenness centrality over
          # a large repo) blocks it for minutes at a time — /health cannot answer
          # while that runs. A tighter probe killed the container mid-index on
          # 2026-08-14 and then did it again on the restart, which is why the
          # first index stalled at 36 of 42 repos. Liveness here is only meant to
          # catch a genuinely dead process, so it tolerates ~5 minutes of
          # unresponsiveness; readiness tolerates ~90s so a normal indexing phase
          # does not flap the Service endpoint.
          liveness_probe {
            http_get {
              path = "/health"
              port = local.api_port
            }
            period_seconds    = 30
            timeout_seconds   = 15
            failure_threshold = 10
          }
          readiness_probe {
            http_get {
              path = "/health"
              port = local.api_port
            }
            period_seconds    = 15
            timeout_seconds   = 10
            failure_threshold = 6
          }

          resources {
            # Burstable on purpose: idle serving is a few hundred Mi, while an
            # incremental reindex spikes with tree-sitter parse workers.
            # Right-size with krr once a week of real data exists.
            requests = {
              memory = "768Mi"
              cpu    = "50m"
            }
            limits = {
              memory = "3Gi"
            }
          }
        }

        # ---------------------------------------------------------------
        # web — the Next.js dashboard. SSR talks to the API over loopback;
        # the browser talks to it same-origin through Traefik.
        # ---------------------------------------------------------------
        container {
          name        = "web"
          image       = local.image
          working_dir = "/app/web"
          command     = ["node", "server.js"]

          port {
            name           = "web"
            container_port = local.web_port
          }

          env {
            name  = "PORT"
            value = tostring(local.web_port)
          }
          env {
            name  = "HOSTNAME"
            value = "0.0.0.0"
          }
          env {
            # Server-side rendering only. The browser bundle's base URL is
            # empty (baked at build time) so client requests are same-origin.
            name  = "REPOWISE_API_URL"
            value = "http://localhost:${local.api_port}"
          }
          env {
            name = "REPOWISE_API_KEY"
            value_from {
              secret_key_ref {
                name = "repowise-secrets"
                key  = "api_key"
              }
            }
          }

          liveness_probe {
            tcp_socket {
              port = local.web_port
            }
            initial_delay_seconds = 15
            period_seconds        = 30
          }
          readiness_probe {
            tcp_socket {
              port = local.web_port
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          resources {
            requests = {
              memory = "256Mi"
              cpu    = "10m"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }

        # ---------------------------------------------------------------
        # mcp — what agents actually consume. streamable-http on /mcp.
        # ---------------------------------------------------------------
        container {
          name        = "mcp"
          image       = local.image
          working_dir = local.workspace
          # Not `repowise mcp` directly: the SDK derives a localhost-only Host
          # allowlist from repowise's FastMCP construction, which 421s every
          # request under a real hostname (including the ClusterIP that
          # in-cluster agents use). The launcher sets an allowlist matching
          # where this is actually reachable from, keeping the protection on.
          command = ["python3", "/opt/repowise/mcp_serve.py"]

          port {
            name           = "mcp"
            container_port = local.mcp_port
          }

          env {
            name  = "REPOWISE_HOST"
            value = "0.0.0.0"
          }
          env {
            name  = "REPOWISE_EMBEDDER"
            value = "mock"
          }
          env {
            name  = "REPOWISE_WORKSPACE"
            value = local.workspace
          }
          env {
            name  = "REPOWISE_MCP_PORT"
            value = tostring(local.mcp_port)
          }
          # The Host allowlist the launcher builds. Kept here so the coupling
          # between the Service/ingress names and that allowlist is visible in
          # one place.
          env {
            name  = "MCP_SERVICE_NAME"
            value = "repowise-mcp"
          }
          env {
            name  = "MCP_NAMESPACE"
            value = local.app
          }
          env {
            name  = "MCP_INGRESS_HOST"
            value = "repowise-mcp.viktorbarzin.me"
          }
          env {
            # Silences the unauthenticated-transport warning and signs SSE
            # stream tokens. It does NOT gate the MCP tools — the Traefik
            # bearer middleware is what does that.
            name = "REPOWISE_API_KEY"
            value_from {
              secret_key_ref {
                name = "repowise-secrets"
                key  = "api_key"
              }
            }
          }

          volume_mount {
            name       = "workspace"
            mount_path = local.workspace
          }
          volume_mount {
            name       = "scripts"
            mount_path = "/opt/repowise"
            read_only  = true
          }

          liveness_probe {
            tcp_socket {
              port = local.mcp_port
            }
            initial_delay_seconds = 20
            period_seconds        = 30
          }
          readiness_probe {
            tcp_socket {
              port = local.mcp_port
            }
            initial_delay_seconds = 10
            period_seconds        = 10
          }

          resources {
            requests = {
              memory = "256Mi"
              cpu    = "10m"
            }
            limits = {
              memory = "1Gi"
            }
          }
        }

        # ---------------------------------------------------------------
        # sync — the reconciler. Bootstraps the Corpus, then keeps it in step
        # with Forgejo and asks the API to reindex whatever moved.
        # ---------------------------------------------------------------
        container {
          name        = "sync"
          image       = local.image
          working_dir = local.workspace
          command     = ["python3", "/opt/repowise/reconcile.py"]

          env {
            name  = "REPOWISE_WORKSPACE"
            value = local.workspace
          }
          env {
            # `repowise init --all` picks the first repo alphabetically as the
            # workspace default, which is Website — no source code in it, so
            # every graph view opens empty. The reconciler sets this instead.
            name  = "REPOWISE_DEFAULT_REPO"
            value = "infra"
          }
          env {
            name  = "REPOWISE_API"
            value = "http://localhost:${local.api_port}"
          }
          env {
            name  = "FORGEJO_BASE"
            value = "https://forgejo.viktorbarzin.me"
          }
          env {
            name  = "FORGEJO_OWNER"
            value = "viktor"
          }
          env {
            name  = "FORGEJO_USER"
            value = "viktor"
          }
          env {
            # Hourly. The index is at most this far behind master; repowise's
            # own stale_warning cannot report that lag, because we reindex
            # immediately after fetching and it only compares the index
            # against the local clone.
            name  = "SYNC_INTERVAL_SECONDS"
            value = "3600"
          }
          env {
            name  = "REPOWISE_EMBEDDER"
            value = "mock"
          }
          env {
            name  = "REPOWISE_PARSE_WORKERS"
            value = "4"
          }
          env {
            name = "REPOWISE_API_KEY"
            value_from {
              secret_key_ref {
                name = "repowise-secrets"
                key  = "api_key"
              }
            }
          }
          env {
            name = "FORGEJO_TOKEN"
            value_from {
              secret_key_ref {
                name = "repowise-secrets"
                key  = "forgejo_token"
              }
            }
          }
          env {
            name = "KUMA_PUSH_URL"
            value_from {
              secret_key_ref {
                name = "repowise-secrets"
                key  = "kuma_push_url"
              }
            }
          }

          volume_mount {
            name       = "workspace"
            mount_path = local.workspace
          }
          volume_mount {
            name       = "scripts"
            mount_path = "/opt/repowise"
            read_only  = true
          }

          resources {
            # The first pass runs the whole initial index in here, and
            # `workspace add` indexes each new repo, so this needs real
            # headroom despite being idle most of the time.
            requests = {
              memory = "512Mi"
              cpu    = "50m"
            }
            limits = {
              memory = "2Gi"
            }
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      # KEEL_IGNORE_IMAGE: Keel owns the running tag (policy=patch).
      spec[0].template[0].spec[0].container[0].image,
      spec[0].template[0].spec[0].container[1].image,
      spec[0].template[0].spec[0].container[2].image,
      spec[0].template[0].spec[0].container[3].image,
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["keel.sh/match-tag"],
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_pod_disruption_budget_v1" "repowise" {
  metadata {
    name      = local.app
    namespace = kubernetes_namespace.repowise.metadata[0].name
  }
  spec {
    # max_unavailable (not min_available): with 1 replica, min_available=1
    # would block every voluntary eviction and hang kured drains.
    max_unavailable = "1"
    selector {
      match_labels = {
        app = local.app
      }
    }
  }
}

resource "kubernetes_service" "api" {
  metadata {
    name      = "repowise-api"
    namespace = kubernetes_namespace.repowise.metadata[0].name
    labels = {
      app = local.app
    }
  }
  spec {
    selector = {
      app = local.app
    }
    port {
      name        = "api"
      port        = local.api_port
      target_port = local.api_port
    }
  }
}

resource "kubernetes_service" "web" {
  metadata {
    name      = "repowise-web"
    namespace = kubernetes_namespace.repowise.metadata[0].name
    labels = {
      app = local.app
    }
  }
  spec {
    selector = {
      app = local.app
    }
    port {
      name        = "web"
      port        = local.web_port
      target_port = local.web_port
    }
  }
}

resource "kubernetes_service" "mcp" {
  metadata {
    name      = "repowise-mcp"
    namespace = kubernetes_namespace.repowise.metadata[0].name
    labels = {
      app = local.app
    }
  }
  spec {
    selector = {
      app = local.app
    }
    port {
      name        = "mcp"
      port        = local.mcp_port
      target_port = local.mcp_port
    }
  }
}

# ---------------------------------------------------------------------------
# Ingress. Two hostnames, not one: combining home-lans-only with a proxied
# host would be self-defeating, since cloudflared pod source IPs sit inside
# 10.0.0.0/8 and would satisfy the allowlist (ADR-0021 / CLAUDE.md).
# ---------------------------------------------------------------------------

# The dashboard. No login of its own, so Authentik is the gate.
module "ingress_web" {
  source          = "../../modules/kubernetes/ingress_factory"
  name            = local.app
  namespace       = kubernetes_namespace.repowise.metadata[0].name
  service_name    = kubernetes_service.web.metadata[0].name
  port            = local.web_port
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  dns_type        = "proxied"

  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Repowise"
    "gethomepage.dev/description"  = "Codebase intelligence over the Forgejo Corpus"
    "gethomepage.dev/icon"         = "si-git"
    "gethomepage.dev/group"        = "Core Platform"
    "gethomepage.dev/pod-selector" = ""
  }
}

# The dashboard's data source, on the same host so browser XHR stays
# same-origin. /health and /metrics live at the root of the API app (not under
# /api), so they are routed here too — otherwise they would fall through to
# the Next.js service and 404.
module "ingress_api" {
  source          = "../../modules/kubernetes/ingress_factory"
  name            = "repowise-api"
  host            = local.app
  namespace       = kubernetes_namespace.repowise.metadata[0].name
  service_name    = kubernetes_service.api.metadata[0].name
  port            = local.api_port
  ingress_path    = ["/api", "/health", "/metrics"]
  tls_secret_name = var.tls_secret_name
  # Same Authentik gate as the dashboard: same-origin XHR carries the session
  # cookie, and repowise's own bearer (from the settings page, held in
  # localStorage) applies underneath it. Nothing programmatic needs /api —
  # agents use /mcp — so gating it costs nothing.
  auth     = "required"
  dns_type = "proxied"
  # Shares a hostname with ingress_web, which already carries the external
  # monitor. Without this opt-out both proxied ingresses annotate the same host
  # and external-monitor-sync creates a duplicate monitor for it.
  external_monitor = false
}

# What agents consume. Internal-only, because this answers questions about
# every private repo in the Corpus.
module "ingress_mcp" {
  source          = "../../modules/kubernetes/ingress_factory"
  name            = "repowise-mcp"
  namespace       = kubernetes_namespace.repowise.metadata[0].name
  service_name    = kubernetes_service.mcp.metadata[0].name
  port            = local.mcp_port
  ingress_path    = ["/mcp"]
  tls_secret_name = var.tls_secret_name
  # auth = "none": MCP clients are programmatic and cannot complete a
  # forward-auth redirect. The gates here are the home-LAN allowlist plus the
  # per-holder bearer middleware below — the latter matters because repowise's
  # MCP HTTP transport performs no authentication of its own.
  auth     = "none"
  dns_type = "internal"
  # Internal-only: an external probe through Cloudflare could never reach it,
  # and the default opt-in would have external-monitor-sync create a monitor
  # that is red by construction.
  external_monitor = false
  extra_middlewares = [
    # Must precede the allowlist: a middleware only intercepts what is
    # downstream of it, and the allowlist short-circuits without calling next.
    "traefik-error-pages-403@kubernetescrd",
    "traefik-home-lans-only@kubernetescrd",
    "repowise-bearer-auth@kubernetescrd",
  ]
  depends_on = [kubernetes_manifest.bearer_middleware]
}
