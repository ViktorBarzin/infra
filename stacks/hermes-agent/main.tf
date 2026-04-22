variable "tls_secret_name" {
  type      = string
  sensitive = true
}

# --- Namespace ---

resource "kubernetes_namespace" "hermes_agent" {
  metadata {
    name = "hermes-agent"
    labels = {
      tier = local.tiers.aux
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

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
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
      dataFrom = [{
        extract = {
          key = "hermes-agent"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.hermes_agent]
}

# --- Storage ---

resource "kubernetes_persistent_volume_claim" "data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "hermes-agent-data-proxmox"
    namespace = kubernetes_namespace.hermes_agent.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
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
}

# --- ConfigMaps ---

resource "kubernetes_config_map" "hermes_config" {
  metadata {
    name      = "hermes-agent-config"
    namespace = kubernetes_namespace.hermes_agent.metadata[0].name
  }
  data = {
    "config.yaml" = yamlencode({
      # Primary model — Qwen 3.5 397B via NVIDIA NIM (free tier)
      # api_key is injected by init container from the secret
      model = {
        provider       = "custom"
        default        = "qwen/qwen3.5-397b-a17b"
        base_url       = "https://integrate.api.nvidia.com/v1"
        api_key        = "__NVIDIA_API_KEY_PLACEHOLDER__"
        context_window = 262000
      }

      # Terminal execution
      terminal = {
        backend = "local"
      }

      # Memory system
      memory = {
        memory_enabled       = true
        user_profile_enabled = true
        memory_char_limit    = 2200
        user_char_limit      = 1375
      }

      # Context compression
      compression = {
        enabled      = true
        threshold    = 0.50
        target_ratio = 0.20
        protect_last_n = 20
      }

      # Security
      security = {
        redact_secrets = true
      }

      # Display
      display = {
        streaming = true
      }

      # Web tools
      web = {
        backend = "tavily"
      }

      # Agent behavior
      agent = {
        max_turns        = 90
        api_timeout      = 90
        reasoning_effort = "medium"
      }

      # Telegram DM policy
      unauthorized_dm_behavior = "ignore"

      # MCP servers — claude-memory for persistent cross-session memory
      mcp_servers = {
        claude-memory = {
          url = "http://claude-memory.claude-memory.svc.cluster.local/mcp/mcp"
          headers = {
            Authorization = "Bearer $${CLAUDE_MEMORY_API_KEY}"
          }
        }
      }
    })
  }
}

resource "kubernetes_config_map" "hermes_soul" {
  metadata {
    name      = "hermes-agent-soul"
    namespace = kubernetes_namespace.hermes_agent.metadata[0].name
  }
  data = {
    "SOUL.md" = <<-EOT
# Hermes - Viktor's Personal AI Assistant

You are Hermes, a knowledgeable and helpful AI assistant owned and operated by
Viktor Barzin. You run on Viktor's home lab Kubernetes cluster and are powered
by Anthropic Claude.

## Personality
- Direct and concise, no unnecessary fluff
- Technical when needed, plain language when possible
- Honest about limitations and uncertainties
- Proactive — suggest improvements, flag risks, follow up on open items

## Owner
- Viktor Barzin — software engineer based in London
- Runs a home lab with a 5-node Kubernetes cluster on Proxmox
- Infrastructure managed with Terraform/Terragrunt
- Uses Vault for secrets, Traefik for ingress, Authentik for SSO

## Your Capabilities
- Terminal: local execution inside your container (Python, Node.js, git, ripgrep, ffmpeg)
- Memory: you have access to claude-memory MCP for persistent cross-session memory
  - Always check memory at the start of conversations for context
  - Store important decisions, learnings, and user preferences
- Skills: you can create and refine your own skills over time
- Web: search and fetch capabilities for research

## Package Persistence
Your container restarts lose system packages. To make installs survive restarts:
- **pip**: packages auto-persist to /opt/data/pip-packages/ (PIP_TARGET is set)
- **npm -g**: packages auto-persist to /opt/data/npm-global/ (NPM_CONFIG_PREFIX is set)
- **apt**: after installing system packages, save them:
  `apt install -y foo bar && echo -e "foo\nbar" >> /opt/data/apt-packages.txt && sort -u -o /opt/data/apt-packages.txt /opt/data/apt-packages.txt`
  They will be auto-reinstalled on next container restart.

## Communication Preferences
- Viktor prefers terse, technical responses
- No emojis unless asked
- Lead with the answer, not the reasoning
- When unsure, say so rather than guessing
    EOT
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
  }
  spec {
    strategy {
      type = "Recreate"
    }
    # Disabled 2026-04-22 — main container fails with "mkdir: cannot create directory '/opt/data': Permission denied" (fsGroup/runAsUser mismatch vs init container). Re-enable after fixing PVC permissions.
    replicas = 0
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
        # Init container 1: bootstrap config into writable PVC
        init_container {
          name  = "bootstrap-config"
          image = "docker.io/library/busybox:1.37"
          command = ["sh", "-c", <<-EOF
            # Create subdirectories
            mkdir -p /opt/data/memories /opt/data/skills /opt/data/sessions /opt/data/cron /opt/data/logs
            mkdir -p /opt/data/pip-packages/bin /opt/data/npm-global/bin

            # Copy config from ConfigMap and inject secrets
            cp /config/config.yaml /opt/data/config.yaml
            cp /soul/SOUL.md /opt/data/SOUL.md

            # Replace API key placeholder with actual value from secret
            NVIDIA_KEY=$(cat /secrets/NVIDIA_API_KEY)
            sed -i "s|__NVIDIA_API_KEY_PLACEHOLDER__|$${NVIDIA_KEY}|g" /opt/data/config.yaml

            # Generate .env from mounted secret files
            echo "# Auto-generated from Vault secret/hermes-agent" > /opt/data/.env
            for f in /secrets/*; do
              key=$(basename "$f")
              val=$(cat "$f")
              echo "$${key}=$${val}" >> /opt/data/.env
            done

            # Fix ownership (hermes container user)
            chown -R 1000:1000 /opt/data
          EOF
          ]
          volume_mount {
            name       = "data"
            mount_path = "/opt/data"
          }
          volume_mount {
            name       = "config"
            mount_path = "/config"
          }
          volume_mount {
            name       = "soul"
            mount_path = "/soul"
          }
          volume_mount {
            name       = "secrets"
            mount_path = "/secrets"
          }
        }

        container {
          name  = "hermes-agent"
          image = "nousresearch/hermes-agent:latest"
          # Wrap entrypoint: restore apt packages (as root) then hand off to original entrypoint
          command = ["bash", "-c", <<-EOF
            if [ -f /opt/data/apt-packages.txt ] && [ -s /opt/data/apt-packages.txt ]; then
              echo "Restoring apt packages: $(cat /opt/data/apt-packages.txt | tr '\n' ' ')"
              apt-get update -qq && \
              xargs -a /opt/data/apt-packages.txt apt-get install -y -qq --no-install-recommends 2>&1 | tail -5
              echo "Done restoring apt packages"
            fi
            exec /opt/hermes/docker/entrypoint.sh gateway run
          EOF
          ]

          env {
            name  = "HERMES_HOME"
            value = "/opt/data"
          }

          # Persist pip packages across restarts
          env {
            name  = "PIP_TARGET"
            value = "/opt/data/pip-packages"
          }
          env {
            name  = "PYTHONPATH"
            value = "/opt/data/pip-packages"
          }

          # Persist npm global packages across restarts
          env {
            name  = "NPM_CONFIG_PREFIX"
            value = "/opt/data/npm-global"
          }

          # Add persistent bin dirs to PATH
          env {
            name  = "PATH"
            value = "/opt/data/pip-packages/bin:/opt/data/npm-global/bin:/opt/data/apt-local/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
          }

          volume_mount {
            name       = "data"
            mount_path = "/opt/data"
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "512Mi"
            }
            limits = {
              memory = "1Gi"
            }
          }

          liveness_probe {
            exec {
              command = ["pgrep", "-f", "hermes"]
            }
            initial_delay_seconds = 30
            period_seconds        = 30
            failure_threshold     = 3
          }
        }

        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data_proxmox.metadata[0].name
          }
        }
        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.hermes_config.metadata[0].name
          }
        }
        volume {
          name = "soul"
          config_map {
            name = kubernetes_config_map.hermes_soul.metadata[0].name
          }
        }
        volume {
          name = "secrets"
          secret {
            secret_name = "hermes-agent-secrets"
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
  }
}

# --- Service ---

resource "kubernetes_service" "hermes_agent" {
  metadata {
    name      = "hermes-agent"
    namespace = kubernetes_namespace.hermes_agent.metadata[0].name
    labels = {
      app = "hermes-agent"
    }
  }
  spec {
    selector = {
      app = "hermes-agent"
    }
    port {
      port        = 80
      target_port = 8642
    }
  }
}

# --- Ingress ---

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.hermes_agent.metadata[0].name
  name            = "hermes-agent"
  tls_secret_name = var.tls_secret_name
  protected       = true
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Hermes Agent"
    "gethomepage.dev/description"  = "Self-improving AI agent"
    "gethomepage.dev/icon"         = "mdi-robot"
    "gethomepage.dev/group"        = "AI & Data"
    "gethomepage.dev/pod-selector" = ""
  }
}
