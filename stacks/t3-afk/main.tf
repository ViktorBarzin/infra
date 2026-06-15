# =============================================================================
# t3-afk — dedicated, in-cluster T3 Code instance: the EXECUTOR + COCKPIT for the
# AFK implementation pipeline (slice #2 of claude-agent-service PRD #1).
#
# claude-agent-service (control plane) dispatches issues INTO this T3 instance
# over its orchestration HTTP API; T3 runs the issue-implementer agent in a git
# worktree and shows every worker in its cockpit. See:
#   claude-agent-service/docs/2026-06-14-afk-implementation-pipeline-design.md
#   claude-agent-service/docs/adr/0003-t3-thin-executor-and-cockpit.md
#
# PILOT SHORTCUT (chosen 2026-06-14): no custom-built image. We run stock
# `node:24` (the full image ships git + python3/make/g++ for node-pty) and an
# init container installs PINNED npm packages (t3@0.0.27 + the Claude CLI) onto
# the SSD PVC, cached across restarts. Formalize a digest-pinned built image
# post-GO. T3 is version-pinned (npm) and NOT Keel-enrolled.
# =============================================================================

# No plan-time Vault reads — every secret flows through the ExternalSecret below
# (CLAUDE_CODE_OAUTH_TOKEN / GITHUB_TOKEN / FORGEJO_TOKEN), injected as env at
# runtime. Nothing here needs a secret value at plan time.

# Wildcard TLS secret name — value comes from config.tfvars; consumed by the
# ingress factory (every stack that uses the factory declares this).
variable "tls_secret_name" {}

locals {
  namespace = "t3-afk"
  # Stock node base — the FULL node:24 (not -slim) is buildpack-deps-based, so it
  # ships git + build-essential (python3/make/g++) that node-pty + the agent need.
  # Fully-qualified (docker.io/library/...) to satisfy the Kyverno
  # require-trusted-registries allowlist via `docker.io/*` — bare `node*` is NOT
  # on the bare-DockerHub-library list (alpine*/busybox*/python* are).
  image = "docker.io/library/node:24"
  # Pinned npm versions installed at startup (the reproducibility anchor for the
  # pilot until a digest-pinned image exists).
  t3_version         = "0.0.27"
  claude_cli_version = "latest" # @anthropic-ai/claude-code
  labels = {
    app = "t3-afk"
  }
}

# --- Namespace ---

resource "kubernetes_namespace" "t3_afk" {
  metadata {
    name = local.namespace
    labels = {
      tier = local.tiers.aux
    }
  }
}

# --- Secrets ---
# The Claude provider authenticates with CLAUDE_CODE_OAUTH_TOKEN (T3 passes the
# environment straight through to the embedded claude-agent-sdk + claude CLI).
# GITHUB_TOKEN / FORGEJO_TOKEN authenticate the agent's `git push` from worktrees
# (wired into ~/.gitconfig insteadOf rewrites in the container command).

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "t3-afk-secrets"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = { name = "t3-afk-secrets" }
      data = [
        {
          secretKey = "CLAUDE_CODE_OAUTH_TOKEN"
          remoteRef = { key = "claude-agent-service", property = "claude_oauth_token" }
        },
        {
          secretKey = "GITHUB_TOKEN"
          remoteRef = { key = "viktor", property = "github_pat" }
        },
        {
          # Shared viktor-scoped admin PAT (also used by Woodpecker + the
          # claude-agent pod). Lets the agent git push / open PRs on Forgejo.
          secretKey = "FORGEJO_TOKEN"
          remoteRef = { key = "ci/global", property = "forgejo_push_token" }
        },
      ]
    }
  }
  depends_on = [kubernetes_namespace.t3_afk]
}

# issue-implementer behaviour. T3 hardcodes the claude_code system-prompt preset
# (no API override), but loads settingSources [user,project,local] — so the
# agent's standing instructions ride in the USER-level ~/.claude/CLAUDE.md, while
# each target repo's own CLAUDE.md provides project context. ADR 0003.
resource "kubernetes_config_map" "agent_claudemd" {
  metadata {
    name      = "issue-implementer-claudemd"
    namespace = kubernetes_namespace.t3_afk.metadata[0].name
  }
  data = {
    "CLAUDE.md" = file("${path.module}/files/issue-implementer-CLAUDE.md")
  }
}

# --- Storage ---
# SSD-NFS (small-file friendly) for the T3 base dir: state.sqlite + the
# server-signing-key (losing it invalidates every issued bearer), per-thread git
# worktrees, the npm global install, and caches. ADR 0004.
module "data" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "t3-afk-data"
  namespace  = kubernetes_namespace.t3_afk.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs-ssd/t3-afk-data"
  storage    = "30Gi"
}

# --- Deployment ---

resource "kubernetes_deployment" "t3_afk" {
  # Slow first start (image pull + npm install init + ESO secret sync) can
  # exceed the default rollout-wait timeout; verify pod readiness out-of-band.
  wait_for_rollout = false

  metadata {
    name      = "t3-afk"
    namespace = kubernetes_namespace.t3_afk.metadata[0].name
    labels    = local.labels
    # keel.sh/policy=never must be a DEPLOYMENT-level annotation — that's where
    # Keel reads it. (A pod-template label is ignored by Keel, which is why the
    # earlier attempt failed.) The cluster's Kyverno inject-keel-annotations
    # policy is opt-OUT: it stamps policy=patch on any workload that doesn't
    # carry its own keel.sh/policy — and Keel then "patch"-downgraded
    # node:24 -> node:24.0.2 (below t3@0.0.27's required node >=24.10), which
    # crash-looped `t3 serve`. ADR 0003 (Keel-excluded).
    annotations = {
      "keel.sh/policy" = "never"
    }
  }

  spec {
    replicas = 1
    # Single-writer state.sqlite — never run two pods against the same base dir.
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
        security_context {
          run_as_user  = 1000 # node
          run_as_group = 1000
          fs_group     = 1000
        }

        # NFS mounts land root-owned; make /data writable by uid 1000.
        init_container {
          name    = "fix-perms"
          image   = "busybox:1.37"
          command = ["sh", "-c", "mkdir -p /data && chown -R 1000:1000 /data && chmod 0775 /data"]
          security_context {
            run_as_user = 0
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          resources {
            requests = { memory = "32Mi" }
            limits   = { memory = "64Mi" }
          }
        }

        # Install pinned t3 + Claude CLI onto the PVC (cached; skipped if already
        # present). Runs as uid 1000 so the install is owned by the runtime user.
        init_container {
          name  = "install-t3"
          image = local.image
          command = ["bash", "-c", <<-EOF
            set -e
            export npm_config_cache=/data/npm-cache
            export npm_config_prefix=/data/npm-global
            mkdir -p /data/npm-global /data/npm-cache
            if [ ! -x /data/npm-global/bin/t3 ]; then
              echo "installing t3@${local.t3_version} + claude CLI ..."
              npm install -g "t3@${local.t3_version}" "@anthropic-ai/claude-code@${local.claude_cli_version}"
            else
              echo "t3 already installed: $(/data/npm-global/bin/t3 --version 2>/dev/null || echo unknown)"
            fi
          EOF
          ]
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          resources {
            requests = { cpu = "200m", memory = "512Mi" }
            limits   = { memory = "1Gi" }
          }
        }

        container {
          name  = "t3"
          image = local.image

          # Configure git auth for the agent's pushes, then run T3 headless.
          # $$ escapes Terraform interpolation so the shell expands the env vars.
          command = ["bash", "-c", <<-EOF
            set -e
            export PATH=/data/npm-global/bin:$$PATH
            export npm_config_cache=/data/npm-cache

            # git identity + token rewrites so the agent can push from worktrees.
            git config --global user.name "issue-implementer (AFK)"
            git config --global user.email "afk-agent@viktorbarzin.me"
            git config --global url."https://$${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"
            git config --global url."https://$${GITHUB_TOKEN}@github.com/".insteadOf "git@github.com:"
            if [ -n "$${FORGEJO_TOKEN}" ]; then
              git config --global url."https://$${FORGEJO_TOKEN}@forgejo.viktorbarzin.me/".insteadOf "https://forgejo.viktorbarzin.me/"
            fi

            exec t3 serve --mode web --host 0.0.0.0 --port 3773 --base-dir /data/t3
          EOF
          ]

          port {
            container_port = 3773
          }

          env_from {
            secret_ref {
              name = "t3-afk-secrets"
            }
          }

          env {
            name  = "HOME"
            value = "/home/node"
          }
          env {
            name  = "T3CODE_HOME"
            value = "/data/t3"
          }

          # T3's API needs auth even for liveness; use a TCP probe on the port.
          liveness_probe {
            tcp_socket {
              port = 3773
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }
          readiness_probe {
            tcp_socket {
              port = 3773
            }
            initial_delay_seconds = 15
            period_seconds        = 10
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          # User-level agent instructions (settingSources: user).
          volume_mount {
            name       = "agent-claudemd"
            mount_path = "/home/node/.claude/CLAUDE.md"
            sub_path   = "CLAUDE.md"
          }

          # Burstable (tier-aux). A live agent thread (node + claude) is memory
          # heavy; size for a small number of concurrent threads on this pilot
          # instance. No CPU limit per cluster policy.
          resources {
            requests = {
              cpu    = "1"
              memory = "2Gi"
            }
            # Capped at the tier-aux LimitRange max (4Gi/container). If real
            # workloads OOM, opt the namespace out via the
            # resource-governance/custom-limitrange label (as claude-agent-service
            # does) and raise this.
            limits = {
              memory = "4Gi"
            }
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = module.data.claim_name
          }
        }

        volume {
          name = "agent-claudemd"
          config_map {
            name = kubernetes_config_map.agent_claudemd.metadata[0].name
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      # Kyverno's inject-keel-annotations stamps pollSchedule/trigger alongside
      # the policy; we own keel.sh/policy=never above, but ignore these two so
      # they don't perpetually drift the plan.
      metadata[0].annotations["keel.sh/pollSchedule"],
      metadata[0].annotations["keel.sh/trigger"],
    ]
  }
}

# --- Service ---

resource "kubernetes_service" "t3_afk" {
  metadata {
    name      = "t3-afk"
    namespace = kubernetes_namespace.t3_afk.metadata[0].name
    labels    = local.labels
  }
  spec {
    selector = local.labels
    port {
      port        = 3773
      target_port = 3773
    }
    type = "ClusterIP"
  }
}

# --- Ingress ---
# The cockpit has no built-in user auth, so Authentik forward-auth is the gate.
module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  auth            = "required"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.t3_afk.metadata[0].name
  name            = "t3-afk"
  service_name    = kubernetes_service.t3_afk.metadata[0].name
  port            = 3773
  tls_secret_name = var.tls_secret_name
}
