# Hermes v2 — Viktor's personal assistant: a Discord bot on the Claude Code
# harness (claude-agent-sdk) with self-contained homelab powers. Rewrites the
# parked Nous-framework stack (replicas=0 since 2026-04-22).
# Design: docs/plans/2026-07-12-hermes-agent-v2-discord-claude-design.md
# Spec:   ViktorBarzin/infra#75 · Code: forgejo viktor/hermes-agent
#
# GO-LIVE PRECONDITION (Viktor, manual — Discord app creation is hCaptcha-gated,
# can't be automated): create the "Hermes" Discord app + bot, enable the
# Message Content + Server Members intents, then
#   vault kv patch secret/hermes-agent \
#     DISCORD_BOT_TOKEN=<bot token> \
#     DISCORD_GUILD_ID=<your private guild id> \
#     HERMES_OWNER_USER_ID=<your discord user id>
# and invite the bot to the guild. The pod CrashLoops without a valid
# DISCORD_BOT_TOKEN — expected until the token is set.

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

locals {
  image     = "ghcr.io/viktorbarzin/hermes-agent"
  image_tag = "latest"
}

# --- Namespace ---

resource "kubernetes_namespace" "hermes_agent" {
  metadata {
    name = "hermes-agent"
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
  namespace       = kubernetes_namespace.hermes_agent.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# --- Secrets (ESO from Vault) ---
# Explicit per-key refs (not dataFrom): the Discord + memory keys live in
# secret/hermes-agent; the Claude OAuth token is CROSS-PATH-extracted from
# secret/claude-agent-service (reused credential, design decision #7); the
# Forgejo push token comes from the shared secret/ci/global.

resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "hermes-agent-secrets"
      namespace = "hermes-agent"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "hermes-agent-secrets"
      }
      data = [
        {
          secretKey = "DISCORD_BOT_TOKEN"
          remoteRef = { key = "hermes-agent", property = "DISCORD_BOT_TOKEN" }
        },
        {
          secretKey = "DISCORD_GUILD_ID"
          remoteRef = { key = "hermes-agent", property = "DISCORD_GUILD_ID" }
        },
        {
          secretKey = "HERMES_OWNER_USER_ID"
          remoteRef = { key = "hermes-agent", property = "HERMES_OWNER_USER_ID" }
        },
        {
          secretKey = "CLAUDE_MEMORY_API_KEY"
          remoteRef = { key = "hermes-agent", property = "CLAUDE_MEMORY_API_KEY" }
        },
        {
          # Reused Claude Code OAuth token (design decision #7) — one credential
          # shared with claude-agent-service; revoking it stops both.
          secretKey = "CLAUDE_CODE_OAUTH_TOKEN"
          remoteRef = { key = "claude-agent-service", property = "claude_oauth_token" }
        },
        {
          # Forgejo push token so the infra checkout can land commits → CI applies.
          secretKey = "FORGEJO_TOKEN"
          remoteRef = { key = "ci/global", property = "forgejo_push_token" }
        },
      ]
    }
  }
  depends_on = [kubernetes_namespace.hermes_agent]
}

# git-crypt key so the infra checkout can decrypt secrets it reads
resource "kubernetes_config_map" "git_crypt_key" {
  metadata {
    name      = "git-crypt-key"
    namespace = kubernetes_namespace.hermes_agent.metadata[0].name
  }
  data = {
    "key" = filebase64("${path.root}/../../.git/git-crypt/keys/default")
  }
}

# --- SOUL (system prompt) ConfigMap — overrides the in-image SOUL.md ---

resource "kubernetes_config_map" "soul" {
  metadata {
    name      = "hermes-agent-soul"
    namespace = kubernetes_namespace.hermes_agent.metadata[0].name
  }
  data = {
    "SOUL.md" = file("${path.module}/SOUL.md")
  }
}

# --- ServiceAccount + RBAC ---
# Read/list/watch everything + pod logs + the debug verbs (delete pods,
# patch deployments for rollout-restart). DELIBERATELY EXCLUDES cluster-wide
# `secrets` read and `pods/exec` — either would let a steered Hermes read the
# breakglass SSH key (K8s secret in ns claude-breakglass) past the Vault deny
# that keeps untrusted-input agents away from root-on-devvm (adversarial-review
# finding; design §3.4). Widen only on Viktor's explicit say-so.

resource "kubernetes_service_account" "hermes_agent" {
  metadata {
    name      = "hermes-agent"
    namespace = kubernetes_namespace.hermes_agent.metadata[0].name
  }
}

resource "kubernetes_cluster_role" "hermes_agent" {
  metadata {
    name = "hermes-agent"
  }
  rule {
    verbs      = ["get", "list", "watch"]
    api_groups = ["", "apps", "batch", "networking.k8s.io"]
    resources = [
      "pods", "pods/log", "nodes", "events", "deployments", "services",
      "namespaces", "jobs", "cronjobs", "configmaps", "replicasets",
      "statefulsets", "daemonsets", "ingresses", "persistentvolumeclaims",
      "endpoints", "resourcequotas",
    ]
  }
  # rollout-restart / scale debugging
  rule {
    verbs      = ["patch", "update"]
    api_groups = ["apps"]
    resources  = ["deployments", "statefulsets"]
  }
  # delete a wedged pod (debug)
  rule {
    verbs      = ["delete"]
    api_groups = [""]
    resources  = ["pods"]
  }
}

resource "kubernetes_cluster_role_binding" "hermes_agent" {
  metadata {
    name = "hermes-agent"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.hermes_agent.metadata[0].name
    namespace = kubernetes_namespace.hermes_agent.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.hermes_agent.metadata[0].name
  }
}

# --- Storage ---
# Sessions PVC holds the SDK transcripts (CLAUDE_CONFIG_DIR=/sessions) +
# the conversation->session map. Encrypted: conversations contain infra detail.

resource "kubernetes_persistent_volume_claim" "sessions_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "hermes-agent-sessions-encrypted"
    namespace = kubernetes_namespace.hermes_agent.metadata[0].name
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
    ignore_changes = [spec[0].resources[0].requests]
  }
}

# --- Deployment ---

resource "kubernetes_deployment" "hermes_agent" {
  metadata {
    name      = "hermes-agent"
    namespace = kubernetes_namespace.hermes_agent.metadata[0].name
    labels = {
      app  = "hermes-agent"
      tier = local.tiers.aux
    }
    annotations = {
      "keel.sh/policy"       = "force"
      "keel.sh/trigger"      = "poll"
      "keel.sh/pollSchedule" = "@every 5m"
      "keel.sh/match-tag"    = "true"
    }
  }
  spec {
    strategy {
      type = "Recreate" # RWO sessions volume
    }
    replicas = 1
    selector {
      match_labels = {
        app = "hermes-agent"
      }
    }
    template {
      metadata {
        labels = {
          app = "hermes-agent"
        }
        annotations = {
          "reloader.stakater.com/search" = "true"
        }
      }
      spec {
        service_account_name = kubernetes_service_account.hermes_agent.metadata[0].name
        security_context {
          fs_group = 1000 # PVC + git-crypt writable by the hermes user (uid 1000)
        }
        # PRIVATE ghcr.io/viktorbarzin/hermes-agent — the ghcr-credentials
        # Secret is cloned into this namespace by the kyverno
        # sync-ghcr-credentials allowlist policy (add "hermes-agent" there).
        image_pull_secrets {
          name = "ghcr-credentials"
        }

        # Init: clone the infra repo + unlock git-crypt (commit->CI apply path)
        init_container {
          name  = "git-init"
          image = "${local.image}:${local.image_tag}"
          command = ["sh", "-c", <<-EOF
            set -e
            git config --global user.name "Hermes Agent"
            git config --global user.email "hermes-agent@viktorbarzin.me"
            git config --global --add safe.directory /workspace/infra
            if [ -n "$${FORGEJO_TOKEN}" ]; then
              git config --global url."https://$${FORGEJO_TOKEN}@forgejo.viktorbarzin.me/".insteadOf "https://forgejo.viktorbarzin.me/"
            fi
            if [ ! -d /workspace/infra/.git ]; then
              git clone https://forgejo.viktorbarzin.me/viktor/infra.git /workspace/infra
            else
              cd /workspace/infra && git fetch origin && git reset --hard origin/master
            fi
            cd /workspace/infra
            git-crypt unlock /secrets/git-crypt/key || true
          EOF
          ]
          env_from {
            secret_ref {
              name = "hermes-agent-secrets"
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
        }

        container {
          name  = "hermes-agent"
          image = "${local.image}:${local.image_tag}"

          # Symlink ~/.vault-token at the sidecar-refreshed token before exec
          # so the homelab / vault CLIs the agent shells out to pick it up.
          command = ["sh", "-c", "ln -sfn /vault/token \"$HOME/.vault-token\" 2>/dev/null; exec python main.py"]

          env_from {
            secret_ref {
              name = "hermes-agent-secrets"
            }
          }
          env {
            name  = "HERMES_SESSIONS_DIR"
            value = "/sessions"
          }
          env {
            # SDK transcripts live on the PVC so conversations survive restarts.
            name  = "CLAUDE_CONFIG_DIR"
            value = "/sessions"
          }
          env {
            name  = "HERMES_WORKDIR"
            value = "/workspace/infra"
          }
          env {
            name  = "HERMES_SOUL_PATH"
            value = "/soul/SOUL.md"
          }
          env {
            name  = "HERMES_METRICS_PORT"
            value = "9090"
          }
          env {
            name  = "VAULT_ADDR"
            value = "https://vault.viktorbarzin.me"
          }
          # EXECUTOR_MCP_URL is intentionally UNSET at v1. Executor's /mcp
          # speaks MCP OAuth (verified 2026-07-12: 401 + oauth-protected-
          # resource metadata), so wiring Hermes to it needs a client
          # credential minted in the Executor UI — Viktor's "configure
          # integrations" step. Set EXECUTOR_MCP_URL (+ token) here once minted.

          volume_mount {
            name       = "sessions"
            mount_path = "/sessions"
          }
          volume_mount {
            name       = "workspace"
            mount_path = "/workspace"
          }
          volume_mount {
            name       = "soul"
            mount_path = "/soul"
          }
          volume_mount {
            name       = "git-crypt-key"
            mount_path = "/secrets/git-crypt"
          }
          # Shared Vault token written by the vault-token-refresher sidecar.
          volume_mount {
            name       = "vault-token"
            mount_path = "/vault"
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

          port {
            name           = "metrics"
            container_port = 9090
          }

          liveness_probe {
            exec {
              command = ["pgrep", "-f", "main.py"]
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            failure_threshold     = 3
          }
        }

        # vault-token-refresher: k8s-auth login on the dedicated hermes-agent
        # Vault role -> shared emptyDir. Mirrors the claude-agent-service sidecar.
        container {
          name  = "vault-token-refresher"
          image = "docker.io/curlimages/curl:8.11.0"
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
            value = "hermes-agent"
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
          name = "sessions"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.sessions_encrypted.metadata[0].name
          }
        }
        volume {
          name = "workspace"
          empty_dir {}
        }
        volume {
          name = "soul"
          config_map {
            name = kubernetes_config_map.soul.metadata[0].name
          }
        }
        volume {
          name = "git-crypt-key"
          config_map {
            name = kubernetes_config_map.git_crypt_key.metadata[0].name
          }
        }
        volume {
          name = "vault-token"
          empty_dir {}
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
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE
      spec[0].template[0].spec[0].init_container[0].image,
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
  }
}

# --- Service (Prometheus scrape target only; no ingress — Discord is outbound) ---

resource "kubernetes_service" "hermes_agent" {
  metadata {
    name      = "hermes-agent"
    namespace = kubernetes_namespace.hermes_agent.metadata[0].name
    labels = {
      app = "hermes-agent"
    }
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/port"   = "9090"
    }
  }
  spec {
    selector = {
      app = "hermes-agent"
    }
    port {
      name        = "metrics"
      port        = 9090
      target_port = 9090
    }
  }
}
