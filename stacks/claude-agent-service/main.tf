data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "claude-agent-service"
}

data "vault_kv_secret_v2" "viktor_secrets" {
  mount = "secret"
  name  = "viktor"
}

locals {
  namespace = "claude-agent"
  # Phase 3 cutover 2026-05-07 — see infra/docs/plans/2026-05-07-forgejo-registry-consolidation-plan.md.
  image     = "ghcr.io/viktorbarzin/claude-agent-service"
  image_tag = "latest"
  labels = {
    app = "claude-agent-service"
  }
}

# --- Namespace ---

resource "kubernetes_namespace" "claude_agent" {
  metadata {
    name = local.namespace
    labels = {
      tier                                    = local.tiers.aux
      "resource-governance/custom-limitrange" = "true"
      "resource-governance/custom-quota"      = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# --- Secrets ---

resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "claude-agent-secrets"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "claude-agent-secrets"
      }
      data = [
        {
          secretKey = "GITHUB_TOKEN"
          remoteRef = {
            key      = "viktor"
            property = "github_pat"
          }
        },
        {
          # Forgejo REPO-scoped PAT (read+write:repository) so the exec agent can
          # clone/branch/push Forgejo repos and open PRs via the API. The old
          # forgejo_push_token here was package-registry-scoped ONLY (no
          # read/write:repository), so git clone/push + the PR API silently 403'd.
          # secret/ci/global/forgejo_repo_token is viktor's git PAT (2026-07-25).
          # SECURITY: the shared claude-agent pod (all agents) can now clone/push
          # + open PRs on any Forgejo repo this PAT reaches — f1-source-fixer needs
          # it to land f1-stream link fixes on the canonical Forgejo master.
          secretKey = "FORGEJO_TOKEN"
          remoteRef = {
            key      = "ci/global"
            property = "forgejo_repo_token"
          }
        },
        {
          secretKey = "API_BEARER_TOKEN"
          remoteRef = {
            key      = "claude-agent-service"
            property = "api_bearer_token"
          }
        },
        {
          # The fixer's own Forgejo identity: the `infra-agent` bot account's PAT
          # (write:repository + write:issue, minted 2026-08-25). Deliberately NOT
          # viktor's PAT — every comment, label, commit and close the fixer makes
          # is attributed to the bot, which is also what makes the webhook's loop
          # guard a one-line author check.
          secretKey = "FIXER_FORGEJO_TOKEN"
          remoteRef = {
            key      = "claude-agent-service"
            property = "forgejo_agent_token"
          }
        },
        {
          # HMAC secret shared with the Forgejo webhook on viktor/infra. Without
          # it the receiver refuses every delivery: an unsigned endpoint that
          # dispatches a cluster-write agent is not a state worth having.
          secretKey = "FIXER_WEBHOOK_SECRET"
          remoteRef = {
            key      = "claude-agent-service"
            property = "fixer_webhook_secret"
          }
        },
        {
          # Memory API key, so a run can recall what earlier runs learned and
          # record what it learned itself. Without it every run starts blind
          # about faults it has already diagnosed once.
          secretKey = "MEMORY_API_KEY"
          remoteRef = {
            key      = "claude-memory"
            property = "api_key"
          }
        },
        {
          # Doorbell publish token. This ntfy is NTFY_AUTH_DEFAULT_ACCESS=deny-all,
          # so an unauthenticated POST is a 403 and no escalation reaches anyone.
          # The token belongs to a dedicated `fixer` user with WRITE-ONLY access to
          # the single `fixer` topic — not the admin account.
          secretKey = "FIXER_NTFY_TOKEN"
          remoteRef = {
            key      = "claude-agent-service"
            property = "fixer_ntfy_token"
          }
        },
        {
          # Long-lived OAuth token (1-year) from `claude setup-token`.
          # Preferred over the short-lived .credentials.json — CLI picks this up and
          # skips the refresh flow entirely. Rotate yearly; alert 30d before expiry.
          secretKey = "CLAUDE_CODE_OAUTH_TOKEN"
          remoteRef = {
            key      = "claude-agent-service"
            property = "claude_oauth_token"
          }
        },
        {
          # Consumed by service-upgrade agent to poll ci.viktorbarzin.me
          # per-workflow status. Pod has no Vault CLI auth, so the old
          # `vault kv get` path is dead — see bd code-3o3.
          secretKey = "WOODPECKER_API_TOKEN"
          remoteRef = {
            key      = "ci/global"
            property = "woodpecker_api_token"
          }
        },
        {
          # Consumed by service-upgrade agent for Start/Success/Failure
          # notifications. Same shared webhook as alertmanager.
          secretKey = "SLACK_WEBHOOK_URL"
          remoteRef = {
            key      = "viktor"
            property = "alertmanager_slack_api_url"
          }
        },
        {
          # Home Assistant MCP endpoint (community ha-mcp add-on on ha-sofia).
          # The URL embeds a secret path-token, so it ships as a secret, not a
          # literal. Referenced as ${HA_MCP_URL} by the project-scoped .mcp.json
          # in the infra repo root. Same Vault key OpenClaw uses
          # (secret/openclaw -> ha_sofia_mcp_url).
          secretKey = "HA_MCP_URL"
          remoteRef = {
            key      = "openclaw"
            property = "ha_sofia_mcp_url"
          }
        },
      ]
    }
  }
  depends_on = [kubernetes_namespace.claude_agent]
}

# SOPS age key for terraform state decryption
resource "kubernetes_secret" "sops_age_key" {
  metadata {
    name      = "sops-age-key"
    namespace = kubernetes_namespace.claude_agent.metadata[0].name
  }
  data = {
    "keys.txt" = data.vault_kv_secret_v2.viktor_secrets.data["sops_age_key_devvm"]
  }
  type = "Opaque"
}

# Claude OAuth credentials (for claude -p)
resource "kubernetes_secret" "claude_credentials" {
  metadata {
    name      = "claude-credentials"
    namespace = kubernetes_namespace.claude_agent.metadata[0].name
  }
  data = {
    ".credentials.json" = data.vault_kv_secret_v2.secrets.data["claude_credentials_json"]
  }
  type = "Opaque"
}

# git-crypt key for repo decryption
resource "kubernetes_config_map" "git_crypt_key" {
  metadata {
    name      = "git-crypt-key"
    namespace = kubernetes_namespace.claude_agent.metadata[0].name
  }
  binary_data = {
    "key" = filebase64("${path.root}/../../.git/git-crypt/keys/default")
  }
}

# --- RBAC ---

resource "kubernetes_service_account" "claude_agent" {
  metadata {
    name      = "claude-agent"
    namespace = kubernetes_namespace.claude_agent.metadata[0].name
  }
}

resource "kubernetes_cluster_role" "claude_agent" {
  metadata {
    name = "claude-agent"
  }

  rule {
    verbs      = ["get", "list", "watch"]
    api_groups = ["", "apps", "batch"]
    resources  = ["pods", "pods/log", "nodes", "events", "deployments", "services", "namespaces", "jobs", "cronjobs", "configmaps", "replicasets", "statefulsets", "daemonsets"]
  }

  rule {
    verbs      = ["patch", "update"]
    api_groups = ["apps"]
    resources  = ["deployments"]
  }

  rule {
    verbs      = ["create"]
    api_groups = [""]
    resources  = ["pods/exec"]
  }
}

resource "kubernetes_cluster_role_binding" "claude_agent" {
  metadata {
    name = "claude-agent"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.claude_agent.metadata[0].name
    namespace = kubernetes_namespace.claude_agent.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.claude_agent.metadata[0].name
  }
}

# -----------------------------------------------------------------------------
# claude-agent-exec — broad cluster WRITE for the executor agent
# -----------------------------------------------------------------------------
# Added 2026-06-04 for the nextcloud-todos-exec executor elevation. The
# existing `claude-agent` ClusterRole above stays as-is (read + patch
# deployments + pods/exec) — this is purely ADDITIVE.
#
# SECURITY — VERY BROAD, FLAG FOR REVIEW:
#   - This grants the SHARED claude-agent pod cluster-wide
#     get/list/watch/create/update/patch/delete across the common API groups
#     below. EVERY agent that runs on this pod inherits it.
#   - It explicitly includes core `secrets` (read+write, cluster-wide) and
#     rbac roles/rolebindings (create/update/delete) — i.e. the agent can
#     read any Secret in any namespace and grant itself further RBAC. That is
#     close to cluster-admin in blast radius, minus a few group wildcards.
#   - It intentionally does NOT bind the built-in `cluster-admin` ClusterRole,
#     so it lacks: arbitrary CRDs/apiextensions, clusterroles/clusterrolebindings
#     bind/escalate beyond what's listed, raw `*` on `*`. Viktor can widen to
#     `cluster-admin` by swapping the role_ref below if he decides the scoped
#     list is too restrictive.
# Terraform-managed cluster resources must still be changed via `scripts/tg
# apply` (CLAUDE.md Terraform-only rule) — this RBAC is for ad-hoc kubectl
# writes the exec agent needs, not a license to drift Terraform state.
resource "kubernetes_cluster_role" "claude_agent_exec" {
  metadata {
    name = "claude-agent-exec"
  }

  rule {
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
    api_groups = [""]
    resources  = ["pods", "pods/log", "pods/exec", "services", "configmaps", "secrets", "persistentvolumeclaims", "serviceaccounts", "namespaces", "events", "endpoints"]
  }

  rule {
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
    api_groups = ["apps"]
    resources  = ["deployments", "statefulsets", "daemonsets", "replicasets"]
  }

  rule {
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
    api_groups = ["batch"]
    resources  = ["jobs", "cronjobs"]
  }

  rule {
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
    api_groups = ["networking.k8s.io"]
    resources  = ["ingresses", "networkpolicies"]
  }

  rule {
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
    api_groups = ["rbac.authorization.k8s.io"]
    resources  = ["roles", "rolebindings"]
  }
}

resource "kubernetes_cluster_role_binding" "claude_agent_exec" {
  metadata {
    name = "claude-agent-exec"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.claude_agent.metadata[0].name
    namespace = kubernetes_namespace.claude_agent.metadata[0].name
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.claude_agent_exec.metadata[0].name
  }
}

# --- Storage ---
#
# The `workspace` volume in the deployment is intentionally emptyDir — agent
# jobs do fresh git clones each run, so a per-pod scratch dir on node disk
# is faster and isolated. The 10Gi `claude-agent-workspace-encrypted` PVC
# that previously sat next to this comment was created but never wired
# into the deployment (sat idle from 2026-04-15 to 2026-05-11).
#
# For cases where the agent DOES need to persist state across pod restarts
# (caches, ad-hoc outputs, anything that should survive a pod reschedule),
# `module.persistent` below provides a 5Gi NFS-backed RWX volume mounted
# at /persistent for state that should survive a pod reschedule. Since the
# service now runs jobs concurrently (bounded semaphore, no single-flight
# lock), agents sharing /persistent must use per-job paths to avoid races —
# per-job *workspaces* are isolated (own clone under /workspace/jobs/<id>),
# but /persistent is shared.
module "persistent" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "claude-agent-persistent"
  namespace  = kubernetes_namespace.claude_agent.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/claude-agent-persistent"
  storage    = "5Gi"
}

# --- Deployment ---

resource "kubernetes_deployment" "claude_agent" {
  metadata {
    name      = "claude-agent-service"
    namespace = kubernetes_namespace.claude_agent.metadata[0].name
    labels    = local.labels
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
        service_account_name = kubernetes_service_account.claude_agent.metadata[0].name

        image_pull_secrets {
          name = "registry-credentials"
        }

        security_context {
          run_as_user  = 1000
          run_as_group = 1000
          fs_group     = 1000
        }

        # Fix workspace ownership. Kubelet creates the Dockerfile WORKDIR
        # (/workspace/infra) inside the emptyDir as root:gid=fsGroup with
        # the setgid bit — uid 1000 can't write into it without explicit
        # chown + chmod. Pre-create so the path is guaranteed, then chown
        # recursively and chmod the infra subdir for safety.
        init_container {
          name    = "fix-perms"
          image   = "busybox:1.37"
          command = ["sh", "-c", "mkdir -p /workspace/infra /persistent && chown -R 1000:1000 /workspace /persistent && chmod 0775 /workspace/infra /persistent"]
          security_context {
            run_as_user = 0
          }
          volume_mount {
            name       = "workspace"
            mount_path = "/workspace"
          }
          volume_mount {
            name       = "persistent"
            mount_path = "/persistent"
          }
          resources {
            requests = {
              memory = "32Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }
        }

        # Copy Claude credentials to writable volume (CLI needs to refresh OAuth tokens)
        init_container {
          name    = "copy-claude-creds"
          image   = "busybox:1.37"
          command = ["sh", "-c", "cp /secrets/claude/.credentials.json /home/agent/.claude/.credentials.json && chown 1000:1000 /home/agent/.claude/.credentials.json"]
          security_context {
            run_as_user = 0
          }
          volume_mount {
            name       = "claude-credentials-secret"
            mount_path = "/secrets/claude"
          }
          volume_mount {
            name       = "claude-home"
            mount_path = "/home/agent/.claude"
          }
          resources {
            requests = {
              memory = "32Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }
        }

        # Init: clone repo + unlock git-crypt on first run
        init_container {
          name  = "git-init"
          image = "${local.image}:${local.image_tag}"
          command = ["sh", "-c", <<-EOF
            set -e

            # Configure git with HTTPS + PAT
            git config --global user.name "Claude Agent Service"
            git config --global user.email "claude-agent@viktorbarzin.me"
            git config --global --add safe.directory /workspace/infra
            git config --global url."https://$${GITHUB_TOKEN}@github.com/".insteadOf "git@github.com:"
            git config --global url."https://$${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"

            # Authenticate git pushes/clones to Forgejo so the exec agent can
            # branch + push to open PRs on forgejo.viktorbarzin.me. The PR
            # itself is created via the Forgejo API (curl + $FORGEJO_TOKEN);
            # this rewrite only handles the git transport.
            if [ -n "$${FORGEJO_TOKEN}" ]; then
              git config --global url."https://$${FORGEJO_TOKEN}@forgejo.viktorbarzin.me/".insteadOf "https://forgejo.viktorbarzin.me/"
            fi

            # The FIXER pushes as ITSELF, not as viktor. A longer prefix wins in
            # git's insteadOf matching, so this narrows viktor/infra to the
            # infra-agent bot while every other Forgejo repo keeps the rule
            # above (the bot is a collaborator on viktor/infra only, so a
            # blanket switch would break the other agents on this pod).
            #
            # Attribution is the point: the bot already authors every comment,
            # label and close on an issue, and a commit pushed with someone
            # else's credential makes the audit trail say something untrue.
            # infra-agent is on master's push whitelist as of 2026-08-26.
            if [ -n "$${FIXER_FORGEJO_TOKEN}" ]; then
              git config --global url."https://infra-agent:$${FIXER_FORGEJO_TOKEN}@forgejo.viktorbarzin.me/viktor/infra".insteadOf "https://forgejo.viktorbarzin.me/viktor/infra"
            fi

            # Clone or update repo — from FORGEJO, which is canonical.
            #
            # This used to clone the GitHub MIRROR, and that silently threw away
            # an agent's work: a fix pushed to the mirror is downstream of
            # Forgejo, so the next Forgejo->GitHub sync force-overwrites it. The
            # 2026-08-28 drill caught it — the run committed c526d61f, pushed it
            # to github.com, reported success (the push really did exit 0), and
            # the commit is now on no branch anywhere. `ref #N` was wrong for the
            # same reason: it resolved against GitHub's issue numbers, not the
            # tracker the run was dispatched from.
            #
            # The credential lives in the remote URL rather than an insteadOf
            # rule, because git config set HERE belongs to the init container and
            # never reaches the container the agent runs in. That is also why the
            # rules above are inert for pushes; they are kept only for anything
            # the init container itself does.
            FORGEJO_ORIGIN="https://infra-agent:$${FIXER_FORGEJO_TOKEN}@forgejo.viktorbarzin.me/viktor/infra.git"
            if [ ! -d /workspace/infra/.git ]; then
              git clone "$${FORGEJO_ORIGIN}" /workspace/infra
            else
              cd /workspace/infra
              # Repoint an existing clone, so a pod that survives this change
              # stops pushing to the mirror.
              git remote set-url origin "$${FORGEJO_ORIGIN}"
              git fetch origin
              git reset --hard origin/master
            fi

            # Unlock git-crypt
            cd /workspace/infra
            git-crypt unlock /secrets/git-crypt/key || true
          EOF
          ]

          env_from {
            secret_ref {
              name = "claude-agent-secrets"
            }
          }

          volume_mount {
            name       = "workspace"
            mount_path = "/workspace"
          }
          volume_mount {
            name       = "git-crypt-key"
            mount_path = "/secrets/git-crypt"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }

        # Seed beads metadata + beads-task-runner agent into runtime volumes.
        # The Dockerfile stages these files at /usr/share/agent-seed/ (image
        # layer, never mounted). Both /workspace (PVC) and /home/agent/.claude
        # (emptyDir) are volume mounts that hide any image-layer content, so
        # the files have to be copied in at pod start. Also creates the
        # scratch directory the beads-task-runner rails expect.
        init_container {
          name  = "seed-beads-agent"
          image = "${local.image}:${local.image_tag}"
          command = ["sh", "-c", <<-EOT
            set -e
            mkdir -p /workspace/.beads /workspace/scratch /home/agent/.claude/agents
            cp /usr/share/agent-seed/beads-metadata.json /workspace/.beads/metadata.json
            cp /usr/share/agent-seed/beads-task-runner.md /home/agent/.claude/agents/beads-task-runner.md
            cp /usr/share/agent-seed/recruiter-triage.md /home/agent/.claude/agents/recruiter-triage.md
            cp /usr/share/agent-seed/nextcloud-todos-planner.md /home/agent/.claude/agents/nextcloud-todos-planner.md
            cp /usr/share/agent-seed/nextcloud-todos-exec.md /home/agent/.claude/agents/nextcloud-todos-exec.md
          EOT
          ]

          volume_mount {
            name       = "workspace"
            mount_path = "/workspace"
          }
          volume_mount {
            name       = "claude-home"
            mount_path = "/home/agent/.claude"
          }

          resources {
            requests = {
              memory = "32Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }
        }

        container {
          name  = "claude-agent-service"
          image = "${local.image}:${local.image_tag}"

          # Wrap the image CMD so a Vault token is in place before any agent
          # runs `scripts/tg apply`. The `vault-token-refresher` sidecar
          # k8s-auth-logs-in (role=terraform-state) and writes the token to the
          # shared `vault-token` emptyDir at /vault/token; we symlink
          # $HOME/.vault-token → that file so `vault` / `scripts/tg` (which fall
          # through to ~/.vault-token when $VAULT_TOKEN is unset) pick it up.
          # NOTE: this duplicates the image's CMD (uvicorn line below) — if the
          # Dockerfile CMD changes, update this too. FLAG for review.
          command = ["/bin/sh", "-c", <<-EOF
            ln -sfn /vault/token "$HOME/.vault-token"
            exec python3 -m uvicorn app.main:app --host 0.0.0.0 --port 8080 --app-dir /srv
          EOF
          ]

          port {
            container_port = 8080
          }

          env_from {
            secret_ref {
              name = "claude-agent-secrets"
            }
          }

          env {
            name  = "WORKSPACE_DIR"
            value = "/workspace/infra"
          }

          # Soft-unbounded concurrency: this caps simultaneous agent runs;
          # excess calls queue FIFO rather than 409/503. Each run peaks ~0.5-1.5Gi
          # (claude + terraform), so this and the memory limit are sized together.
          env {
            name  = "MAX_CONCURRENCY"
            value = "10"
          }

          # Vault — so `scripts/tg apply` can fetch the Tier-1 PG backend
          # password + the broadened app-secret reads. The CLI + scripts/tg
          # fall through to $HOME/.vault-token (symlinked above) when
          # $VAULT_TOKEN is unset; VAULT_K8S_ROLE tells the refresher which
          # role to log in as.
          env {
            name  = "VAULT_ADDR"
            value = "http://vault-active.vault.svc.cluster.local:8200"
          }
          env {
            name  = "VAULT_K8S_ROLE"
            value = "terraform-state"
          }

          # ------------------------------------------------------------------ #
          # The fixer — a `broken` issue on Forgejo repairs itself.
          # docs: claude-agent-service/docs/2026-08-25-forgejo-fixer-design.md
          #
          # ARMED. Both gates are deliberate and independent (the loop ships
          # disabled): AFK_KILL_SWITCH must be false AND AFK_ALLOWLIST must name
          # the repo. Setting either back disables the fixer without touching
          # code — that is the global brake. The per-issue brake is the `paused`
          # label, which needs no deploy at all.
          # ------------------------------------------------------------------ #
          env {
            name  = "AFK_KILL_SWITCH"
            value = "false"
          }
          env {
            name  = "AFK_ALLOWLIST"
            value = "infra"
          }
          env {
            name  = "AFK_READY_LABEL"
            value = "broken"
          }

          # No budget or timeout ceiling on a fixer run (design decision 14): a
          # hard diagnosis is never truncated, and burn rate is bounded by the
          # per-repo lock — one run at a time — instead. Leaving
          # FIXER_MAX_BUDGET_USD / FIXER_TIMEOUT_SECONDS unset is what expresses
          # that; setting either puts a ceiling back.
          env {
            name  = "FIXER_FORGEJO_API"
            value = "https://forgejo.viktorbarzin.me/api/v1"
          }
          env {
            name  = "FIXER_FORGEJO_WEB"
            value = "https://forgejo.viktorbarzin.me"
          }
          env {
            name  = "FIXER_FORGEJO_OWNER"
            value = "viktor"
          }
          env {
            name  = "FIXER_BOT_ACTOR"
            value = "infra-agent"
          }
          env {
            name  = "FIXER_AGENT"
            value = "issue-responder"
          }
          # The homelab CLI reads these. Reachability verified from this pod:
          # loki.viktorbarzin.lan resolves and answers, claude-memory answers 200.
          env {
            name  = "MEMORY_API_URL"
            value = "https://claude-memory.viktorbarzin.me"
          }
          env {
            name  = "CLAUDE_MEMORY_API_URL"
            value = "https://claude-memory.viktorbarzin.me"
          }
          env {
            name = "CLAUDE_MEMORY_API_KEY"
            value_from {
              secret_key_ref {
                name = "claude-agent-secrets"
                key  = "MEMORY_API_KEY"
              }
            }
          }

          env {
            name  = "FIXER_NTFY_URL"
            value = "https://ntfy.viktorbarzin.me"
          }
          env {
            name  = "FIXER_NTFY_TOPIC"
            value = "fixer"
          }
          # Woodpecker is the decisive CI stage for infra: .woodpecker/default.yml
          # runs on push and is what applies the change.
          env {
            name  = "FIXER_WOODPECKER_URL"
            value = "http://woodpecker-server.woodpecker.svc.cluster.local"
          }
          env {
            name  = "FIXER_WOODPECKER_REPO_ID"
            value = "1"
          }
          env {
            name = "FIXER_WOODPECKER_TOKEN"
            value_from {
              secret_key_ref {
                name = "claude-agent-secrets"
                key  = "WOODPECKER_API_TOKEN"
              }
            }
          }

          # NOTE on MCP: the HA MCP URL (secret — its path segment is the auth
          # token) arrives as env `HA_MCP_URL` via the claude-agent-secrets
          # ExternalSecret (env_from above), sourced from Vault
          # secret/openclaw -> ha_sofia_mcp_url. The project-scoped .mcp.json
          # in the infra repo root references it as ${HA_MCP_URL}. Paperless
          # MCP needs no token in-cluster (bearer is enforced only at the
          # Traefik ingress), so its in-cluster Service URL is a plain literal
          # in .mcp.json.

          liveness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 10
            period_seconds        = 30
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          volume_mount {
            name       = "workspace"
            mount_path = "/workspace"
          }
          volume_mount {
            name       = "persistent"
            mount_path = "/persistent"
          }
          volume_mount {
            name       = "sops-age-key"
            mount_path = "/home/agent/.config/sops/age"
          }
          volume_mount {
            name       = "claude-home"
            mount_path = "/home/agent/.claude"
          }

          # git-crypt key — each job re-unlocks its own clone, so the runtime
          # container (not just the git-init init container) needs the key.
          volume_mount {
            name       = "git-crypt-key"
            mount_path = "/secrets/git-crypt"
          }

          # Shared Vault token written by the vault-token-refresher sidecar.
          # Symlinked to $HOME/.vault-token by the container command above.
          volume_mount {
            name       = "vault-token"
            mount_path = "/vault"
          }

          # Burstable (tier-aux). Sized for ~10 concurrent agent runs at
          # ~0.5-1.5Gi each (see MAX_CONCURRENCY). No CPU limit per cluster
          # policy (CFS throttling); request only.
          resources {
            requests = {
              cpu    = "1"
              memory = "640Mi"
            }
            limits = {
              memory = "3Gi"
            }
          }
        }

        # Sidecar: keep a fresh Vault token on disk for `scripts/tg apply`.
        # k8s-auth login (role=terraform-state) every 30 min — well inside the
        # 6-day token TTL — and write it to the shared `vault-token` emptyDir.
        # The main container symlinks $HOME/.vault-token at it. Mirrors the
        # estate k8s-auth-login pattern (infra/.woodpecker/default.yml "Vault
        # auth" step, woodpecker vault-sync sidecar).
        container {
          name  = "vault-token-refresher"
          image = "docker.io/curlimages/curl:8.11.0"
          # No `set -e`: a transient Vault blip must NOT kill the refresh loop
          # (the stale token keeps working until its 6d TTL). curlimages/curl
          # is Alpine/busybox — has `sed`, no `jq`, so parse client_token with
          # sed. umask 077 so the token file is 0600.
          command = ["/bin/sh", "-c", <<-EOF
            umask 077
            while true; do
              SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
              TOKEN=$(curl -s -X POST "$VAULT_ADDR/v1/auth/kubernetes/login" \
                -d "{\"role\":\"$VAULT_K8S_ROLE\",\"jwt\":\"$SA_TOKEN\"}" \
                | sed -n 's/.*"client_token":"\([^"]*\)".*/\1/p')
              if [ -n "$TOKEN" ]; then
                printf '%s' "$TOKEN" > /vault/token
                echo "$(date -u +%FT%TZ) refreshed vault token (role=$VAULT_K8S_ROLE)"
              else
                echo "$(date -u +%FT%TZ) ERROR: vault k8s login failed (role=$VAULT_K8S_ROLE)" >&2
              fi
              sleep 1800
            done
          EOF
          ]
          env {
            name  = "VAULT_ADDR"
            value = "http://vault-active.vault.svc.cluster.local:8200"
          }
          env {
            name  = "VAULT_K8S_ROLE"
            value = "terraform-state"
          }
          volume_mount {
            name       = "vault-token"
            mount_path = "/vault"
          }
          resources {
            requests = { cpu = "5m", memory = "16Mi" }
            limits   = { memory = "32Mi" }
          }
        }

        volume {
          name = "workspace"
          # Per-pod ephemeral scratch — agent does fresh git clones each
          # job, so node-disk emptyDir is faster than a network-backed PVC
          # and avoids RWO contention across the 3 replicas.
          empty_dir {}
        }

        volume {
          name = "persistent"
          persistent_volume_claim {
            claim_name = module.persistent.claim_name
          }
        }

        volume {
          name = "sops-age-key"
          secret {
            secret_name  = kubernetes_secret.sops_age_key.metadata[0].name
            default_mode = "0600"
          }
        }

        volume {
          name = "git-crypt-key"
          config_map {
            name = kubernetes_config_map.git_crypt_key.metadata[0].name
          }
        }

        volume {
          name = "claude-credentials-secret"
          secret {
            secret_name  = kubernetes_secret.claude_credentials.metadata[0].name
            default_mode = "0600"
          }
        }

        volume {
          name = "claude-home"
          empty_dir {}
        }

        # Holds the Vault token the refresher sidecar mints; main container
        # symlinks $HOME/.vault-token at /vault/token. emptyDir (memory-backed
        # not required) — token is re-minted every 30 min and on pod restart.
        volume {
          name = "vault-token"
          empty_dir {}
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config,
      spec[0].template[0].spec[0].container[1].image, # KEEL_IGNORE_IMAGE
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"],                    # KYVERNO_LIFECYCLE_V2
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
      metadata[0].labels["tier"],                                         # stamped by Kyverno sync-tier-label-from-namespace
      spec[0].template[0].spec[0].container[0].image,                     # KEEL_IGNORE_IMAGE
    ]                                                                     # KYVERNO_LIFECYCLE_V1
  }
}

# --- Service ---

resource "kubernetes_service" "claude_agent" {
  metadata {
    name      = "claude-agent-service"
    namespace = kubernetes_namespace.claude_agent.metadata[0].name
    labels    = local.labels
  }

  spec {
    selector = local.labels

    port {
      port        = 8080
      target_port = 8080
    }

    type = "ClusterIP"
  }
}

# =============================================================================
# Token expiry monitor
# Long-lived CLAUDE_CODE_OAUTH_TOKEN values expire 1y after mint. We track
# mint timestamps here — on rotation, update the map below. A CronJob pushes
# the computed expiry_timestamp to Pushgateway, Prometheus alerts 30d out.
# =============================================================================
locals {
  claude_oauth_token_mint_epochs = {
    # unix seconds (UTC) — when `claude setup-token` finished minting
    "primary" = 1776528429 # 2026-04-18T12:07:09Z  (TOKEN2)
    "spare-1" = 1776528280 # 2026-04-18T12:04:40Z  (TOKEN1)
    "spare-2" = 1776528429 # 2026-04-18T12:07:09Z  (TOKEN2 — redundant w/ primary)
  }
  claude_oauth_token_ttl_seconds = 365 * 24 * 60 * 60
}

resource "kubernetes_config_map" "claude_oauth_expiry" {
  metadata {
    name      = "claude-oauth-expiry"
    namespace = kubernetes_namespace.claude_agent.metadata[0].name
  }
  data = {
    for path, mint in local.claude_oauth_token_mint_epochs :
    path => tostring(mint + local.claude_oauth_token_ttl_seconds)
  }
}

resource "kubernetes_cron_job_v1" "claude_oauth_expiry_monitor" {
  metadata {
    name      = "claude-oauth-expiry-monitor"
    namespace = kubernetes_namespace.claude_agent.metadata[0].name
  }
  spec {
    concurrency_policy            = "Replace"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 1
    schedule                      = "17 */6 * * *" # every 6h at :17 past
    job_template {
      metadata {}
      spec {
        backoff_limit              = 1
        ttl_seconds_after_finished = 300
        template {
          metadata {}
          spec {
            restart_policy = "OnFailure"
            container {
              name  = "push-expiry"
              image = "docker.io/curlimages/curl:8.11.0"
              command = ["/bin/sh", "-c", <<-EOT
                set -e
                PG='http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/claude-oauth-expiry-monitor'
                NOW=$(date +%s)
                PAYLOAD=''
                PAYLOAD="$${PAYLOAD}# HELP claude_oauth_token_expiry_timestamp Unix epoch when the CLAUDE_CODE_OAUTH_TOKEN for this path expires
                "
                PAYLOAD="$${PAYLOAD}# TYPE claude_oauth_token_expiry_timestamp gauge
                "
                for path in /mnt/expiry/*; do
                  name=$(basename "$path")
                  exp=$(cat "$path")
                  PAYLOAD="$${PAYLOAD}claude_oauth_token_expiry_timestamp{path=\"$name\"} $exp
                "
                done
                PAYLOAD="$${PAYLOAD}# HELP claude_oauth_expiry_monitor_last_push_timestamp Last time the expiry monitor pushed metrics
                "
                PAYLOAD="$${PAYLOAD}# TYPE claude_oauth_expiry_monitor_last_push_timestamp gauge
                "
                PAYLOAD="$${PAYLOAD}claude_oauth_expiry_monitor_last_push_timestamp $NOW
                "
                echo "$PAYLOAD"
                echo "$PAYLOAD" | curl -sS --data-binary @- "$PG"
                echo "pushed at $NOW"
              EOT
              ]
              volume_mount {
                name       = "expiry"
                mount_path = "/mnt/expiry"
              }
              resources {
                requests = { cpu = "10m", memory = "32Mi" }
                limits   = { memory = "64Mi" }
              }
            }
            volume {
              name = "expiry"
              config_map {
                name = kubernetes_config_map.claude_oauth_expiry.metadata[0].name
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

# -----------------------------------------------------------------------------
# fixer-tick — the half of the fixer loop a webhook cannot do
# -----------------------------------------------------------------------------
# The webhook dispatches immediately when the repo is free. This tick covers the
# two things it cannot: DRAINING a `broken` issue that arrived while a run held
# the per-repo lock, and FOLLOWING a pushed commit through CI — turning a red
# pipeline into a corrective turn (fix forward, never revert).
#
# It holds no state. What is in flight is the `agent-in-progress` label on the
# issue, and where each run got to is a hidden footer on its own comment, so a
# tick in a fresh pod resumes exactly where the last one stopped.
#
# Design: claude-agent-service/docs/2026-08-25-forgejo-fixer-design.md
#
# concurrency_policy Forbid: two ticks would race on the same lock and could
# double-dispatch. A skipped tick costs at most one interval of latency.
resource "kubernetes_cron_job_v1" "fixer_tick" {
  metadata {
    name      = "fixer-tick"
    namespace = kubernetes_namespace.claude_agent.metadata[0].name
    labels    = local.labels
  }

  spec {
    schedule                      = "*/2 * * * *"
    concurrency_policy            = "Forbid"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    starting_deadline_seconds     = 60

    job_template {
      metadata {}
      spec {
        backoff_limit              = 0
        ttl_seconds_after_finished = 600
        template {
          metadata {
            labels = local.labels
          }
          spec {
            restart_policy       = "Never"
            service_account_name = kubernetes_service_account.claude_agent.metadata[0].name
            container {
              name  = "tick"
              image = "${local.image}:${local.image_tag}"
              # The app is baked at /srv (the server runs uvicorn --app-dir /srv),
              # so a bare `python3 -m app.fixer.tick` from / cannot import it.
              working_dir = "/srv"
              command     = ["python3", "-m", "app.fixer.tick"]

              # Every FIXER_*/AFK_* value and both secrets come from the same
              # places the service itself reads them, so the tick and the
              # webhook can never disagree about the trigger label, the bot
              # identity, or whether the loop is armed.
              env_from {
                secret_ref {
                  name = "claude-agent-secrets"
                }
              }
              env {
                name  = "FIXER_SERVICE_URL"
                value = "http://claude-agent-service.${local.namespace}.svc.cluster.local:8080"
              }
              env {
                name  = "AFK_KILL_SWITCH"
                value = "false"
              }
              env {
                name  = "AFK_ALLOWLIST"
                value = "infra"
              }
              env {
                name  = "AFK_READY_LABEL"
                value = "broken"
              }
              env {
                name  = "FIXER_FORGEJO_API"
                value = "https://forgejo.viktorbarzin.me/api/v1"
              }
              env {
                name  = "FIXER_FORGEJO_WEB"
                value = "https://forgejo.viktorbarzin.me"
              }
              env {
                name  = "FIXER_FORGEJO_OWNER"
                value = "viktor"
              }
              env {
                name  = "FIXER_BOT_ACTOR"
                value = "infra-agent"
              }
              env {
                name  = "FIXER_AGENT"
                value = "issue-responder"
              }
              env {
                name  = "FIXER_NTFY_URL"
                value = "https://ntfy.viktorbarzin.me"
              }
              env {
                name  = "FIXER_NTFY_TOPIC"
                value = "fixer"
              }
              env {
                name  = "FIXER_WOODPECKER_URL"
                value = "http://woodpecker-server.woodpecker.svc.cluster.local"
              }
              env {
                name  = "FIXER_WOODPECKER_REPO_ID"
                value = "1"
              }
              # TEMPORARY, for the fix-forward drill (2026-08-28). Makes the
              # FIRST CI verdict for any commit come back red, so one corrective
              # cycle runs; every later verdict for that commit is the real one.
              # Remove once the drill has proven the branch — leaving it on would
              # cost one extra fix-forward turn on every real fix.
              env {
                name  = "FIXER_CI_FORCE_RED_ONCE"
                value = "1"
              }
              env {
                name = "FIXER_WOODPECKER_TOKEN"
                value_from {
                  secret_key_ref {
                    name = "claude-agent-secrets"
                    key  = "WOODPECKER_API_TOKEN"
                  }
                }
              }

              resources {
                requests = { cpu = "20m", memory = "64Mi" }
                limits   = { memory = "192Mi" }
              }
            }
          }
        }
      }
    }
  }
}
