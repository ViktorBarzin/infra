# claude-breakglass — in-cluster emergency-recovery UI for the devvm.
#
# A SEPARATE deployment from claude-agent-service (own namespace, own
# ServiceAccount, NO Vault K8s-auth role) that runs ONLY the breakglass agent.
# It shares the claude-agent-service image but overrides the command with the
# breakglass entrypoint. The untrusted-input agents (recruiter-triage,
# nextcloud-todos) never share this process or these credentials.
# See claude-agent-service/docs/adr/0001-breakglass-security-architecture.md.
#
# Scope is the WARM case: devvm wedged while the cluster is healthy. The cold,
# cluster-down path is the break-glass SSH on PVE :52222 (docs/runbooks/breakglass-ssh.md)
# + the server-lifecycle iDRAC CLI — out of scope here.

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

locals {
  namespace = "claude-breakglass"
  # Same image as claude-agent-service — the breakglass code lives in that repo
  # under app/breakglass/, and the deployment below overrides the command.
  image     = "ghcr.io/viktorbarzin/claude-agent-service"
  image_tag = "latest"
  labels = {
    app = "claude-breakglass"
  }
}

# --- Namespace ---

resource "kubernetes_namespace" "breakglass" {
  metadata {
    name = local.namespace
    labels = {
      tier = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks/vpa-mode label stamping (harmless if absent)
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_service_account" "breakglass" {
  metadata {
    name      = "claude-breakglass"
    namespace = kubernetes_namespace.breakglass.metadata[0].name
  }
}

# --- Secrets (synced by ESO; the pod itself has NO Vault access) ---

# SSH private key (devvm sudo + PVE forced-command). Mounted as a file the
# entrypoint loads into ssh-agent. Dedicated path secret/claude-breakglass/* —
# the claude-agent namespace's terraform-state Vault policy is explicitly
# DENIED this path (see stacks/vault/main.tf) so the shared, prompt-injectable
# pod can never read it.
resource "kubernetes_manifest" "external_secret_ssh" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "breakglass-ssh"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { name = "vault-kv", kind = "ClusterSecretStore" }
      target          = { name = "breakglass-ssh" }
      data = [
        {
          secretKey = "private_key"
          remoteRef = { key = "claude-breakglass/ssh_key", property = "private_key" }
        },
      ]
    }
  }
  depends_on = [kubernetes_namespace.breakglass]
}

# Env secrets: the Anthropic OAuth token (shared with claude-agent-service —
# same account) and the app bearer token (in-cluster/CLI fallback caller auth).
resource "kubernetes_manifest" "external_secret_env" {
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "breakglass-env"
      namespace = local.namespace
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef  = { name = "vault-kv", kind = "ClusterSecretStore" }
      target          = { name = "breakglass-env" }
      data = [
        {
          secretKey = "CLAUDE_CODE_OAUTH_TOKEN"
          remoteRef = { key = "claude-agent-service", property = "claude_oauth_token" }
        },
        {
          secretKey = "API_BEARER_TOKEN"
          remoteRef = { key = "claude-breakglass", property = "api_bearer_token" }
        },
      ]
    }
  }
  depends_on = [kubernetes_namespace.breakglass]
}

# --- Deployment ---

resource "kubernetes_deployment" "breakglass" {
  metadata {
    name      = "claude-breakglass"
    namespace = kubernetes_namespace.breakglass.metadata[0].name
    labels    = local.labels
  }

  spec {
    replicas = 1
    strategy { type = "Recreate" }
    selector { match_labels = local.labels }

    template {
      metadata { labels = local.labels }

      spec {
        service_account_name = kubernetes_service_account.breakglass.metadata[0].name

        image_pull_secrets {
          name = "registry-credentials"
        }

        # Survive the very pressure event the breakglass exists to fix: high
        # priority (resist eviction), tolerate node pressure, and prefer NOT to
        # land on the contended GPU node1. Pull policy is Always: nodes already
        # cache the OLD claude-agent-service:latest (no breakglass entrypoint),
        # so IfNotPresent would run stale code. A registry-down-on-restart is
        # the cluster-down (cold) case, which this UI doesn't cover anyway.
        priority_class_name = "tier-0-core"

        toleration {
          key      = "node.kubernetes.io/memory-pressure"
          operator = "Exists"
          effect   = "NoSchedule"
        }
        toleration {
          key      = "node.kubernetes.io/disk-pressure"
          operator = "Exists"
          effect   = "NoSchedule"
        }
        toleration {
          key                = "node.kubernetes.io/not-ready"
          operator           = "Exists"
          effect             = "NoExecute"
          toleration_seconds = 300
        }
        toleration {
          key                = "node.kubernetes.io/unreachable"
          operator           = "Exists"
          effect             = "NoExecute"
          toleration_seconds = 300
        }

        affinity {
          node_affinity {
            preferred_during_scheduling_ignored_during_execution {
              weight = 100
              preference {
                match_expressions {
                  key      = "kubernetes.io/hostname"
                  operator = "NotIn"
                  values   = ["k8s-node1"]
                }
              }
            }
          }
        }

        security_context {
          run_as_user  = 1000
          run_as_group = 1000
          fs_group     = 1000
        }

        # Seed the breakglass agent into the fresh ~/.claude emptyDir and make
        # the session dir writable by uid 1000.
        init_container {
          name  = "seed-agent"
          image = "${local.image}:${local.image_tag}"
          command = ["sh", "-c", <<-EOT
            set -e
            mkdir -p /home/agent/.claude/agents /workspace/sessions
            cp /usr/share/agent-seed/breakglass.md /home/agent/.claude/agents/breakglass.md
            chown -R 1000:1000 /home/agent/.claude /workspace
          EOT
          ]
          image_pull_policy = "Always"
          security_context {
            run_as_user = 0
          }
          volume_mount {
            name       = "claude-home"
            mount_path = "/home/agent/.claude"
          }
          volume_mount {
            name       = "sessions"
            mount_path = "/workspace"
          }
          resources {
            requests = { memory = "32Mi" }
            limits   = { memory = "64Mi" }
          }
        }

        container {
          name              = "claude-breakglass"
          image             = "${local.image}:${local.image_tag}"
          image_pull_policy = "Always"

          # Override the image's default CMD (the claude-agent-service uvicorn)
          # with the breakglass entrypoint: ssh-agent bootstrap + ssh aliases,
          # then uvicorn app.breakglass.server:app.
          command = ["/srv/docker-entrypoint-breakglass.sh"]

          port { container_port = 8080 }

          # OAuth token (claude -p) + app bearer token.
          env_from {
            secret_ref { name = "breakglass-env" }
          }

          env {
            name  = "BREAKGLASS_KEY_PATH"
            value = "/secrets/breakglass/private_key"
          }
          env {
            name  = "BREAKGLASS_SESSIONS_DIR"
            value = "/workspace/sessions"
          }
          env {
            name  = "HOME"
            value = "/home/agent"
          }

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
            name       = "claude-home"
            mount_path = "/home/agent/.claude"
          }
          volume_mount {
            name       = "sessions"
            mount_path = "/workspace"
          }
          volume_mount {
            name       = "breakglass-ssh"
            mount_path = "/secrets/breakglass"
            read_only  = true
          }

          resources {
            requests = {
              cpu    = "200m"
              memory = "512Mi"
            }
            limits = {
              memory = "4Gi"
            }
          }
        }

        volume {
          name = "claude-home"
          empty_dir {}
        }
        volume {
          name = "sessions"
          empty_dir {}
        }
        volume {
          name = "breakglass-ssh"
          secret {
            secret_name = "breakglass-ssh"
            # 0440 + fsGroup 1000 ⇒ readable by uid 1000; the entrypoint copies
            # to a 0600 tmpfs file before ssh-add (which rejects group-readable).
            default_mode = "0440"
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
  }

  depends_on = [
    kubernetes_manifest.external_secret_ssh,
    kubernetes_manifest.external_secret_env,
  ]
}

# --- Service ---

resource "kubernetes_service" "breakglass" {
  metadata {
    name      = "claude-breakglass"
    namespace = kubernetes_namespace.breakglass.metadata[0].name
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

# --- Ingress: breakglass.viktorbarzin.me ---
# auth = "required": Authentik forward-auth via the resilience proxy, which
# FALLS BACK to HTTP basic-auth when Authentik is down — the whole point, so the
# breakglass is reachable during an auth-stack outage. CrowdSec + rate-limit are
# attached by default (not excluded). The app additionally accepts the injected
# X-authentik-username header (or a bearer) as its own gate.
module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  name            = "breakglass"
  service_name    = kubernetes_service.breakglass.metadata[0].name
  port            = 8080
  namespace       = kubernetes_namespace.breakglass.metadata[0].name
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  dns_type        = "proxied"

  extra_annotations = {
    "gethomepage.dev/enabled"     = "true"
    "gethomepage.dev/name"        = "devvm breakglass"
    "gethomepage.dev/description" = "Emergency recovery UI for the devvm"
    "gethomepage.dev/icon"        = "proxmox.png"
    "gethomepage.dev/group"       = "Infrastructure"
  }
}
