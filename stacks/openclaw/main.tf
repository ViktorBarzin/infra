variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "openclaw"
}

locals {
  skill_secrets = jsondecode(data.vault_kv_secret_v2.secrets.data["skill_secrets"])
}


resource "kubernetes_namespace" "openclaw" {
  metadata {
    name = "openclaw"
    labels = {
      tier = local.tiers.aux
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.openclaw.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_service_account" "openclaw" {
  metadata {
    name      = "openclaw"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
  }
}

resource "kubernetes_cluster_role_binding" "openclaw" {
  metadata {
    name = "openclaw-cluster-admin"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.openclaw.metadata[0].name
    namespace = kubernetes_namespace.openclaw.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }
}

resource "kubernetes_secret" "ssh_key" {
  metadata {
    name      = "ssh-key"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
  }
  data = {
    "id_rsa" = data.vault_kv_secret_v2.secrets.data["ssh_key"]
  }
  type = "generic"
}

resource "kubernetes_config_map" "git_crypt_key" {
  metadata {
    name      = "git-crypt-key"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
  }
  data = {
    "key" = filebase64("${path.root}/../../.git/git-crypt/keys/default")
  }
}

resource "kubernetes_config_map" "openclaw_config" {
  metadata {
    name      = "openclaw-config"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
  }
  data = {
    "openclaw.json" = jsonencode({
      gateway = {
        mode           = "local"
        bind           = "lan"
        trustedProxies = ["10.0.0.0/8"]
        controlUi = {
          dangerouslyDisableDeviceAuth             = true
          dangerouslyAllowHostHeaderOriginFallback = true
        }
      }
      agents = {
        defaults = {
          contextTokens     = 1000000
          bootstrapMaxChars = 30000
          workspace         = "/workspace/infra"
          sandbox = {
            mode = "off"
          }
          model = {
            primary   = "anthropic/claude-sonnet-4-20250514"
            fallbacks = ["nim/mistralai/mistral-large-3-675b-instruct-2512", "nim/nvidia/llama-3.1-nemotron-ultra-253b-v1", "modelrelay/auto-fastest"]
          }
          models = {
            "anthropic/claude-sonnet-4-20250514"                     = {}
            "anthropic/claude-opus-4-20250514"                       = {}
            "anthropic/claude-haiku-4-20250506"                      = {}
            "modelrelay/auto-fastest"                                = {}
            "nim/deepseek-ai/deepseek-v3.2"                          = {}
            "nim/qwen/qwen3.5-397b-a17b"                             = {}
            "nim/mistralai/mistral-large-3-675b-instruct-2512"       = {}
            "nim/qwen/qwen3-coder-480b-a35b-instruct"                = {}
            "nim/nvidia/llama-3.1-nemotron-ultra-253b-v1"            = {}
            "nim/z-ai/glm5"                                          = {}
            "llama-as-openai/Llama-4-Maverick-17B-128E-Instruct-FP8" = {}
            "llama-as-openai/Llama-4-Scout-17B-16E-Instruct-FP8"     = {}
            "openrouter/stepfun/step-3.5-flash:free"                 = {}
            "openrouter/arcee-ai/trinity-large-preview:free"         = {}
          }
        }
      }
      tools = {
        profile = "full"
        deny    = []
        elevated = {
          enabled = true
        }
        exec = {
          host        = "gateway"
          security    = "full"
          ask         = "off"
          pathPrepend = ["/tools", "/workspace/infra"]
        }
        web = {
          search = {
            enabled    = true
            provider   = "brave"
            apiKey     = data.vault_kv_secret_v2.secrets.data["brave_api_key"]
            maxResults = 5
          }
          fetch = {
            enabled        = true
            maxChars       = 50000
            timeoutSeconds = 30
          }
        }
      }
      plugins = {
        allow = ["memory-api"]
        slots = {
          memory = "memory-api"
        }
        load = {
          paths = ["/home/node/.openclaw/extensions"]
        }
      }
      commands = {
        native       = true
        nativeSkills = true
      }
      channels = {
        telegram = {
          enabled     = true
          botToken    = data.vault_kv_secret_v2.secrets.data["telegram_bot_token"]
          dmPolicy    = "allowlist"
          allowFrom   = ["tg:8281953845"]
          groupPolicy = "allowlist"
          streamMode  = "partial"
        }
      }
      models = {
        mode = "merge"
        providers = {
          modelrelay = {
            baseUrl = "http://127.0.0.1:7352/v1"
            api     = "openai-completions"
            apiKey  = "modelrelay"
            models = [
              { id = "auto-fastest", name = "Auto (Fastest)", reasoning = false, input = ["text"], contextWindow = 200000, maxTokens = 16384, cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0 } },
            ]
          }
          anthropic = {
            baseUrl = "https://api.anthropic.com/v1"
            api     = "anthropic-messages"
            apiKey  = data.vault_kv_secret_v2.secrets.data["anthropic_api_key"]
            models = [
              { id = "claude-sonnet-4-20250514", name = "Claude Sonnet 4", reasoning = true, input = ["text", "image"], contextWindow = 200000, maxTokens = 16384, cost = { input = 0.003, output = 0.015, cacheRead = 0.0003, cacheWrite = 0.00375 } },
              { id = "claude-opus-4-20250514", name = "Claude Opus 4", reasoning = true, input = ["text", "image"], contextWindow = 200000, maxTokens = 16384, cost = { input = 0.015, output = 0.075, cacheRead = 0.0015, cacheWrite = 0.01875 } },
              { id = "claude-haiku-4-20250506", name = "Claude Haiku 4", reasoning = false, input = ["text", "image"], contextWindow = 200000, maxTokens = 16384, cost = { input = 0.0008, output = 0.004, cacheRead = 0.00008, cacheWrite = 0.001 } },
            ]
          }
          nim = {
            baseUrl = "https://integrate.api.nvidia.com/v1"
            api     = "openai-completions"
            apiKey  = data.vault_kv_secret_v2.secrets.data["nvidia_api_key"]
            models = [
              { id = "deepseek-ai/deepseek-v3.2", name = "DeepSeek V3.2", reasoning = false, input = ["text"], contextWindow = 164000, maxTokens = 16384, cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0 } },
              { id = "qwen/qwen3.5-397b-a17b", name = "Qwen 3.5", reasoning = true, input = ["text"], contextWindow = 262000, maxTokens = 16384, cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0 } },
              { id = "mistralai/mistral-large-3-675b-instruct-2512", name = "Mistral Large 3", reasoning = false, input = ["text"], contextWindow = 262000, maxTokens = 16384, cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0 } },
              { id = "qwen/qwen3-coder-480b-a35b-instruct", name = "Qwen 3 Coder", reasoning = false, input = ["text"], contextWindow = 262000, maxTokens = 16384, cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0 } },
              { id = "nvidia/llama-3.1-nemotron-ultra-253b-v1", name = "Nemotron Ultra 253B", reasoning = true, input = ["text"], contextWindow = 128000, maxTokens = 16384, cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0 } },
              { id = "z-ai/glm5", name = "GLM-5", reasoning = false, input = ["text"], contextWindow = 128000, maxTokens = 16384, cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0 } },
            ]
          }
          openrouter = {
            baseUrl = "https://openrouter.ai/api/v1"
            api     = "openai-completions"
            apiKey  = data.vault_kv_secret_v2.secrets.data["openrouter_api_key"]
            models = [
              { id = "stepfun/step-3.5-flash:free", name = "Step 3.5 Flash", reasoning = true, input = ["text"], contextWindow = 256000, maxTokens = 16384, cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0 } },
              { id = "arcee-ai/trinity-large-preview:free", name = "Trinity Large", reasoning = false, input = ["text"], contextWindow = 131000, maxTokens = 16384, cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0 } },
            ]
          }
          llama-as-openai = {
            baseUrl = "https://api.llama.com/compat/v1"
            apiKey  = data.vault_kv_secret_v2.secrets.data["llama_api_key"]
            api     = "openai-completions"
            models = [
              { id = "Llama-4-Maverick-17B-128E-Instruct-FP8", name = "Llama 4 Maverick", reasoning = false, input = ["text"], contextWindow = 200000, maxTokens = 16384, cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0 } },
              { id = "Llama-4-Scout-17B-16E-Instruct-FP8", name = "Llama 4 Scout", reasoning = false, input = ["text"], contextWindow = 200000, maxTokens = 16384, cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0 } },
            ]
          }
        }
      }
      wizard = {
        lastRunAt      = "2026-03-01T15:11:54.176Z"
        lastRunVersion = "2026.2.9"
        lastRunCommand = "configure"
        lastRunMode    = "local"
      }
    })
  }
}

resource "random_password" "gateway_token" {
  length  = 32
  special = false
}

module "nfs_tools" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "openclaw-tools"
  namespace  = kubernetes_namespace.openclaw.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/openclaw/tools"
}

module "nfs_openclaw_home" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "openclaw-home"
  namespace  = kubernetes_namespace.openclaw.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/openclaw/home"
}

module "nfs_workspace" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "openclaw-workspace"
  namespace  = kubernetes_namespace.openclaw.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/openclaw/workspace"
}

module "nfs_data" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "openclaw-data"
  namespace  = kubernetes_namespace.openclaw.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/openclaw/data"
}

module "nfs_cc_config" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "cc-config"
  namespace  = kubernetes_namespace.openclaw.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/openclaw/cc-config"
}

resource "kubernetes_deployment" "openclaw" {
  metadata {
    name      = "openclaw"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
    labels = {
      app  = "openclaw"
      tier = local.tiers.aux
    }
  }
  spec {
    strategy {
      type = "Recreate"
    }
    replicas = 1
    selector {
      match_labels = {
        app = "openclaw"
      }
    }
    template {
      metadata {
        labels = {
          app = "openclaw"
        }
      }
      spec {
        service_account_name = kubernetes_service_account.openclaw.metadata[0].name

        # Init container: Download tools + clone repo (parallelized, cached on NFS)
        init_container {
          name  = "setup"
          image = "alpine:3.20"
          command = ["sh", "-c", <<-EOF
            set -e
            apk add --no-cache curl unzip git-crypt openssh-client git bash

            # Install Python packages (skip if already cached)
            if [ ! -f /tools/python-libs/.installed ]; then
              python3 -m ensurepip 2>/dev/null || apk add --no-cache py3-pip
              pip3 install --break-system-packages --target=/tools/python-libs requests caldav icalendar uptime-kuma-api
              touch /tools/python-libs/.installed
            else
              echo "Python packages already cached, skipping pip install"
            fi

            # Copy OpenClaw config to writable home dir
            cp /openclaw-config-src/openclaw.json /openclaw-home/openclaw.json

            # Setup SSH key
            mkdir -p /root/.ssh
            cp /ssh/id_rsa /root/.ssh/id_rsa
            chmod 600 /root/.ssh/id_rsa
            ssh-keyscan github.com >> /root/.ssh/known_hosts 2>/dev/null

            # --- Download tools only if missing or version changed ---
            # kubectl
            if [ ! -x /tools/kubectl ]; then
              (curl -sL --retry 3 --retry-delay 5 "https://dl.k8s.io/release/v1.34.2/bin/linux/amd64/kubectl" -o /tools/kubectl && chmod +x /tools/kubectl) &
              PID_KUBECTL=$!
            else
              echo "kubectl already cached" & PID_KUBECTL=$!
            fi

            # terraform
            if [ ! -x /tools/terraform ]; then
              (curl -sL --retry 3 --retry-delay 5 "https://releases.hashicorp.com/terraform/1.14.5/terraform_1.14.5_linux_amd64.zip" -o /tmp/tf.zip && unzip -q /tmp/tf.zip -d /tools && chmod +x /tools/terraform && rm /tmp/tf.zip) &
              PID_TF=$!
            else
              echo "terraform already cached" & PID_TF=$!
            fi

            # terragrunt
            if [ ! -x /tools/terragrunt ]; then
              (curl -sL --retry 3 --retry-delay 5 "https://github.com/gruntwork-io/terragrunt/releases/download/v0.99.4/terragrunt_linux_amd64" -o /tools/terragrunt && chmod +x /tools/terragrunt) &
              PID_TG=$!
            else
              echo "terragrunt already cached" & PID_TG=$!
            fi

            # git-crypt
            if [ ! -x /tools/git-crypt ]; then
              cp /usr/bin/git-crypt /tools/git-crypt
            fi

            # Clone/pull repo
            if [ ! -d /workspace/infra/.git ]; then
              git clone git@github.com:ViktorBarzin/infra.git /workspace/infra &
              PID_GIT=$!
            else
              (cd /workspace/infra && git pull --ff-only || true) &
              PID_GIT=$!
            fi

            # Wait for all parallel tasks
            wait $PID_KUBECTL || { echo "kubectl download failed"; exit 1; }
            wait $PID_TF || { echo "terraform download failed"; exit 1; }
            wait $PID_TG || { echo "terragrunt download failed"; exit 1; }
            wait $PID_GIT || { echo "git clone/pull failed"; exit 1; }

            # Unlock git-crypt (needs clone done)
            cd /workspace/infra
            echo "$GIT_CRYPT_KEY" | base64 -d > /tmp/git-crypt-key
            git-crypt unlock /tmp/git-crypt-key || true
            rm /tmp/git-crypt-key

            # Mark repo as safe for the node user (different UID from init container)
            git config --global --add safe.directory /workspace/infra
            cp /root/.gitconfig /openclaw-home/.gitconfig 2>/dev/null || true
            chown -R 1000:1000 /workspace/infra

            # Symlink Claude skills into OpenClaw skills directory
            ln -sfn /workspace/infra/.claude/skills /openclaw-home/skills

            # Pull shared CC config from NFS bare repo
            if [ ! -d /openclaw-home/cc-config/.git ]; then
              git clone /cc-config/cc-config.git /openclaw-home/cc-config 2>/dev/null || true
            else
              (cd /openclaw-home/cc-config && git pull --ff-only) || true
            fi

            # Apply shared config to OpenClaw
            if [ -d /openclaw-home/cc-config ]; then
              # Copy shared CLAUDE.md (global knowledge)
              [ -f /openclaw-home/cc-config/CLAUDE.md ] && \
                cp /openclaw-home/cc-config/CLAUDE.md /openclaw-home/CLAUDE.md

              # Copy shared skills (separate dir from infra skills)
              if [ -d /openclaw-home/cc-config/skills ]; then
                mkdir -p /openclaw-home/cc-skills
                cp -r /openclaw-home/cc-config/skills/* /openclaw-home/cc-skills/ 2>/dev/null || true
              fi

              # Copy shared memory
              if [ -d /openclaw-home/cc-config/memory ]; then
                mkdir -p /openclaw-home/memory
                cp -r /openclaw-home/cc-config/memory/* /openclaw-home/memory/ 2>/dev/null || true
              fi

              # Copy commands, hooks, agents
              for d in commands hooks agents; do
                if [ -d /openclaw-home/cc-config/$d ]; then
                  mkdir -p /openclaw-home/$d
                  cp -r /openclaw-home/cc-config/$d/* /openclaw-home/$d/ 2>/dev/null || true
                fi
              done
            fi

            # Install memory-api plugin from GitHub (always pull latest)
            if [ -d /openclaw-home/extensions/memory-api/.git ]; then
              (cd /openclaw-home/extensions/memory-api && git pull --ff-only) || true
            else
              rm -rf /openclaw-home/extensions/memory-api
              git clone --depth 1 git@github.com:ViktorBarzin/claude-memory-mcp.git /tmp/claude-memory-mcp
              mkdir -p /openclaw-home/extensions/memory-api
              cp -r /tmp/claude-memory-mcp/openclaw-plugin/* /openclaw-home/extensions/memory-api/
              rm -rf /tmp/claude-memory-mcp
            fi

            # Create required directories (owned by node user, UID 1000)
            mkdir -p /openclaw-home/agents/main/sessions /openclaw-home/credentials /openclaw-home/canvas /openclaw-home/devices /openclaw-home/cron /openclaw-home/cc-skills /openclaw-home/memory
            chown -R 1000:1000 /openclaw-home
            chmod 700 /openclaw-home

            # Generate kubeconfig from in-cluster ServiceAccount credentials
            SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
            SA_CA=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
            cat > /openclaw-home/kubeconfig <<-KUBEEOF
            apiVersion: v1
            kind: Config
            clusters:
            - cluster:
                certificate-authority-data: $(base64 < "$SA_CA" | tr -d '\n')
                server: https://kubernetes.default.svc
              name: in-cluster
            contexts:
            - context:
                cluster: in-cluster
                user: openclaw
              name: in-cluster
            current-context: in-cluster
            users:
            - name: openclaw
              user:
                token: $SA_TOKEN
            KUBEEOF

            echo "Setup complete: kubectl, terraform, terragrunt, git-crypt installed"
          EOF
          ]
          env {
            name = "GIT_CRYPT_KEY"
            value_from {
              config_map_key_ref {
                name = kubernetes_config_map.git_crypt_key.metadata[0].name
                key  = "key"
              }
            }
          }
          volume_mount {
            name       = "tools"
            mount_path = "/tools"
          }
          volume_mount {
            name       = "workspace"
            mount_path = "/workspace"
          }
          volume_mount {
            name       = "ssh-key"
            mount_path = "/ssh"
          }
          volume_mount {
            name       = "openclaw-home"
            mount_path = "/openclaw-home"
          }
          volume_mount {
            name       = "openclaw-config"
            mount_path = "/openclaw-config-src"
          }
          volume_mount {
            name       = "cc-config"
            mount_path = "/cc-config"
          }
        }

        # Main container: OpenClaw
        container {
          name    = "openclaw"
          image   = "ghcr.io/openclaw/openclaw:2026.2.26"
          command = ["sh", "-c", "node openclaw.mjs doctor --fix 2>/dev/null; exec node openclaw.mjs gateway --allow-unconfigured --bind lan"]
          port {
            container_port = 18789
          }
          readiness_probe {
            tcp_socket {
              port = 18789
            }
            initial_delay_seconds = 30
            period_seconds        = 10
          }
          env {
            name  = "OPENCLAW_GATEWAY_TOKEN"
            value = random_password.gateway_token.result
          }
          env {
            name  = "PATH"
            value = "/tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
          }
          env {
            name  = "TF_VAR_prod"
            value = "true"
          }
          env {
            name  = "KUBECONFIG"
            value = "/home/node/.openclaw/kubeconfig"
          }
          env {
            name  = "GIT_CONFIG_GLOBAL"
            value = "/home/node/.openclaw/.gitconfig"
          }
          # Skill secrets - Home Assistant
          env {
            name  = "HOME_ASSISTANT_URL"
            value = "https://ha-london.viktorbarzin.me"
          }
          env {
            name  = "HOME_ASSISTANT_TOKEN"
            value = local.skill_secrets["home_assistant_token"]
          }
          env {
            name  = "HOME_ASSISTANT_SOFIA_URL"
            value = "https://ha-sofia.viktorbarzin.me"
          }
          env {
            name  = "HOME_ASSISTANT_SOFIA_TOKEN"
            value = local.skill_secrets["home_assistant_sofia_token"]
          }
          # Skill secrets - Uptime Kuma
          env {
            name  = "UPTIME_KUMA_PASSWORD"
            value = local.skill_secrets["uptime_kuma_password"]
          }
          # Skill secrets - Slack
          env {
            name  = "SLACK_WEBHOOK_URL"
            value = local.skill_secrets["slack_webhook"]
          }
          # Memory API
          env {
            name  = "MEMORY_API_URL"
            value = "http://claude-memory.claude-memory.svc.cluster.local"
          }
          env {
            name  = "MEMORY_API_KEY"
            value = data.vault_kv_secret_v2.secrets.data["claude_memory_api_key"]
          }
          # Python packages path for skills
          env {
            name  = "PYTHONPATH"
            value = "/tools/python-libs"
          }
          volume_mount {
            name       = "tools"
            mount_path = "/tools"
          }
          volume_mount {
            name       = "workspace"
            mount_path = "/workspace"
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          volume_mount {
            name       = "ssh-key"
            mount_path = "/ssh"
          }
          volume_mount {
            name       = "openclaw-home"
            mount_path = "/home/node/.openclaw"
          }
          resources {
            limits = {
              memory = "768Mi"
            }
            requests = {
              cpu    = "100m"
              memory = "768Mi"
            }
          }
        }

        # Sidecar: modelrelay — auto-routes to fastest healthy free model
        container {
          name  = "modelrelay"
          image = "node:22-alpine"
          command = ["sh", "-c", <<-EOF
            if [ ! -f /tools/modelrelay/node_modules/.package-lock.json ]; then
              mkdir -p /tools/modelrelay
              cd /tools/modelrelay
              npm init -y > /dev/null 2>&1
              npm install modelrelay > /dev/null 2>&1
            fi
            cd /tools/modelrelay
            exec npx modelrelay --port 7352
          EOF
          ]
          port {
            container_port = 7352
          }
          env {
            name  = "NVIDIA_API_KEY"
            value = data.vault_kv_secret_v2.secrets.data["nvidia_api_key"]
          }
          env {
            name  = "OPENROUTER_API_KEY"
            value = data.vault_kv_secret_v2.secrets.data["openrouter_api_key"]
          }
          volume_mount {
            name       = "tools"
            mount_path = "/tools"
          }
          resources {
            limits = {
              memory = "256Mi"
            }
            requests = {
              cpu    = "25m"
              memory = "256Mi"
            }
          }
        }

        volume {
          name = "tools"
          persistent_volume_claim {
            claim_name = module.nfs_tools.claim_name
          }
        }
        volume {
          name = "openclaw-home"
          persistent_volume_claim {
            claim_name = module.nfs_openclaw_home.claim_name
          }
        }
        volume {
          name = "workspace"
          persistent_volume_claim {
            claim_name = module.nfs_workspace.claim_name
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = module.nfs_data.claim_name
          }
        }
        volume {
          name = "ssh-key"
          secret {
            secret_name  = kubernetes_secret.ssh_key.metadata[0].name
            default_mode = "0600"
          }
        }
        volume {
          name = "cc-config"
          persistent_volume_claim {
            claim_name = module.nfs_cc_config.claim_name
          }
        }
        volume {
          name = "openclaw-config"
          config_map {
            name = kubernetes_config_map.openclaw_config.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "openclaw" {
  metadata {
    name      = "openclaw"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
    labels = {
      app = "openclaw"
    }
  }
  spec {
    selector = {
      app = "openclaw"
    }
    port {
      port        = 80
      target_port = 18789
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.openclaw.metadata[0].name
  name            = "openclaw"
  tls_secret_name = var.tls_secret_name
  port            = 80
  protected       = true
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "OpenClaw"
    "gethomepage.dev/description"  = "AI assistant"
    "gethomepage.dev/icon"         = "openai.png"
    "gethomepage.dev/group"        = "AI & Data"
    "gethomepage.dev/pod-selector" = ""
  }
}

# --- Webhook receiver: triggers task-processor Job on Forgejo issue events ---

resource "kubernetes_config_map" "task_webhook" {
  metadata {
    name      = "task-webhook"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
  }
  data = {
    "server.py" = <<-PYEOF
      from http.server import HTTPServer, BaseHTTPRequestHandler
      import subprocess, time, json, os

      BOT_USER = os.environ.get('FORGEJO_BOT_USER', 'viktor')

      class Handler(BaseHTTPRequestHandler):
          def do_POST(self):
              try:
                  body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
                  data = json.loads(body)
                  action = data.get('action', '')

                  # Trigger on: new issue, reopened issue, or new comment
                  trigger = False
                  if action in ('opened', 'reopened'):
                      issue = data.get('issue', {})
                      print(f"Issue #{issue.get('number','?')} {action}: {issue.get('title','?')}")
                      trigger = True
                  elif action == 'created' and 'comment' in data:
                      comment = data.get('comment', {})
                      commenter = comment.get('user', {}).get('login', '')
                      # Skip comments from the bot itself to avoid loops
                      if commenter != BOT_USER:
                          issue = data.get('issue', {})
                          print(f"Comment on #{issue.get('number','?')} by {commenter}")
                          trigger = True
                      else:
                          print(f"Skipping own comment on #{data.get('issue',{}).get('number','?')}")

                  if trigger:
                      job_name = f"task-processor-{int(time.time())}"
                      subprocess.run([
                          'kubectl', 'create', 'job', job_name,
                          '--from=cronjob/task-processor',
                          '-n', 'openclaw'
                      ], check=True)
                      self.send_response(200)
                      self.end_headers()
                      self.wfile.write(b'{"ok":true}')
                  else:
                      self.send_response(200)
                      self.end_headers()
                      self.wfile.write(b'{"ok":true,"skipped":true}')
              except Exception as e:
                  print(f"Error: {e}")
                  self.send_response(500)
                  self.end_headers()
                  self.wfile.write(f'{{"error":"{e}"}}'.encode())

          def do_GET(self):
              self.send_response(200)
              self.end_headers()
              self.wfile.write(b'{"status":"ok"}')

          def log_message(self, fmt, *args):
              print(f"[webhook] {args[0]} {args[1]} {args[2]}")

      print("Task webhook receiver listening on :8080")
      HTTPServer(('', 8080), Handler).serve_forever()
    PYEOF
  }
}

resource "kubernetes_service_account" "task_webhook" {
  metadata {
    name      = "task-webhook"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
  }
}

resource "kubernetes_role" "task_webhook" {
  metadata {
    name      = "task-webhook-job-creator"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
  }
  rule {
    api_groups = ["batch"]
    resources  = ["jobs", "cronjobs"]
    verbs      = ["get", "list", "create"]
  }
}

resource "kubernetes_role_binding" "task_webhook" {
  metadata {
    name      = "task-webhook-job-creator"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.task_webhook.metadata[0].name
    namespace = kubernetes_namespace.openclaw.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.task_webhook.metadata[0].name
  }
}

resource "kubernetes_deployment" "task_webhook" {
  metadata {
    name      = "task-webhook"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
    labels = {
      app  = "task-webhook"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "task-webhook"
      }
    }
    template {
      metadata {
        labels = {
          app = "task-webhook"
        }
      }
      spec {
        service_account_name = kubernetes_service_account.task_webhook.metadata[0].name
        container {
          name    = "webhook"
          image   = "python:3-alpine"
          command = ["sh", "-c", "apk add --no-cache curl > /dev/null 2>&1 && curl -sfL https://dl.k8s.io/release/v1.34.2/bin/linux/amd64/kubectl -o /usr/local/bin/kubectl && chmod +x /usr/local/bin/kubectl && exec python3 -u /app/server.py"]
          port {
            container_port = 8080
          }
          volume_mount {
            name       = "app"
            mount_path = "/app"
          }
          resources {
            requests = {
              cpu    = "5m"
              memory = "64Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }
        }
        volume {
          name = "app"
          config_map {
            name = kubernetes_config_map.task_webhook.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "task_webhook" {
  metadata {
    name      = "task-webhook"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
    labels = {
      app = "task-webhook"
    }
  }
  spec {
    selector = {
      app = "task-webhook"
    }
    port {
      port        = 80
      target_port = 8080
    }
  }
}

module "task_webhook_ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.openclaw.metadata[0].name
  name            = "task-webhook"
  tls_secret_name = var.tls_secret_name
  host            = "task-webhook"
  port            = 80
}

# --- CronJob: Scheduled cluster health check ---

resource "kubernetes_service_account" "healthcheck" {
  metadata {
    name      = "cluster-healthcheck"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
  }
}

resource "kubernetes_role" "healthcheck_exec" {
  metadata {
    name      = "healthcheck-pod-exec"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods/exec"]
    verbs      = ["create"]
  }
}

resource "kubernetes_role_binding" "healthcheck_exec" {
  metadata {
    name      = "healthcheck-pod-exec"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.healthcheck.metadata[0].name
    namespace = kubernetes_namespace.openclaw.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.healthcheck_exec.metadata[0].name
  }
}

resource "kubernetes_cron_job_v1" "cluster_healthcheck" {
  metadata {
    name      = "cluster-healthcheck"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
    labels = {
      app  = "cluster-healthcheck"
      tier = local.tiers.aux
    }
  }
  spec {
    schedule                      = "0 */8 * * *"
    concurrency_policy            = "Forbid"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 3

    job_template {
      metadata {
        labels = {
          app = "cluster-healthcheck"
        }
      }
      spec {
        active_deadline_seconds = 300
        backoff_limit           = 0
        template {
          metadata {
            labels = {
              app = "cluster-healthcheck"
            }
          }
          spec {
            service_account_name = kubernetes_service_account.healthcheck.metadata[0].name
            restart_policy       = "Never"

            container {
              name  = "healthcheck"
              image = "bitnami/kubectl:latest"
              command = ["bash", "-c", <<-EOF
                # Find the openclaw pod
                POD=$(kubectl get pods -n openclaw -l app=openclaw -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
                if [ -z "$POD" ]; then
                  echo "ERROR: OpenClaw pod not found"
                  exit 1
                fi
                echo "Executing health check in pod $POD..."
                kubectl exec -n openclaw "$POD" -c openclaw -- bash /workspace/infra/.claude/cluster-health.sh
              EOF
              ]

              resources {
                requests = {
                  cpu    = "50m"
                  memory = "64Mi"
                }
                limits = {
                  memory = "64Mi"
                }
              }
            }
          }
        }
      }
    }
  }
}

# --- CronJob: Task processor — polls Forgejo issues and triggers OpenClaw ---

resource "kubernetes_cron_job_v1" "task_processor" {
  metadata {
    name      = "task-processor"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
    labels = {
      app  = "task-processor"
      tier = local.tiers.aux
    }
  }
  spec {
    schedule                      = "*/5 * * * *"
    concurrency_policy            = "Forbid"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 3

    job_template {
      metadata {
        labels = {
          app = "task-processor"
        }
      }
      spec {
        active_deadline_seconds = 600
        backoff_limit           = 0
        template {
          metadata {
            labels = {
              app = "task-processor"
            }
          }
          spec {
            service_account_name = kubernetes_service_account.healthcheck.metadata[0].name
            restart_policy       = "Never"

            container {
              name  = "task-processor"
              image = "bitnami/kubectl:latest"
              command = ["bash", "-c", <<-EOF
                # Find the openclaw pod
                POD=$(kubectl get pods -n openclaw -l app=openclaw -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
                if [ -z "$POD" ]; then
                  echo "ERROR: OpenClaw pod not found"
                  exit 1
                fi
                echo "Executing task processor in pod $POD..."
                kubectl exec -n openclaw "$POD" -c openclaw -- \
                  env FORGEJO_TOKEN="$FORGEJO_TOKEN" \
                      OPENCLAW_TOKEN="$OPENCLAW_TOKEN" \
                      OPENCLAW_URL="https://integrate.api.nvidia.com" \
                  bash /workspace/infra/scripts/task-processor.sh
              EOF
              ]

              env {
                name  = "FORGEJO_TOKEN"
                value = data.vault_kv_secret_v2.secrets.data["forgejo_api_token"]
              }
              env {
                name  = "OPENCLAW_TOKEN"
                value = data.vault_kv_secret_v2.secrets.data["nvidia_api_key"]
              }

              resources {
                requests = {
                  cpu    = "50m"
                  memory = "64Mi"
                }
                limits = {
                  memory = "64Mi"
                }
              }
            }
          }
        }
      }
    }
  }
}
