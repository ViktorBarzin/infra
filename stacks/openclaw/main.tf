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

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.openclaw.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "openclaw-secrets"
      namespace = "openclaw"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "openclaw-secrets"
      }
      dataFrom = [{
        extract = {
          key = "openclaw"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.openclaw]
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
          workspace         = "/workspace"
          sandbox = {
            mode = "off"
          }
          model = {
            primary   = "nim/qwen/qwen3.5-397b-a17b"
            fallbacks = ["nim/mistralai/mistral-large-3-675b-instruct-2512", "nim/nvidia/llama-3.1-nemotron-ultra-253b-v1", "modelrelay/auto-fastest"]
          }
          models = {
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
          pathPrepend = ["/tools", "/workspace"]
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
        allow = ["memory-core"]
        slots = { memory = "memory-core" }
        load = {
          paths = ["/home/node/.openclaw/extensions", "/app/extensions"]
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

module "nfs_tools_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "openclaw-tools-host"
  namespace  = kubernetes_namespace.openclaw.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/openclaw/tools"
}

resource "kubernetes_persistent_volume_claim" "home_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "openclaw-home-proxmox"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
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

module "nfs_workspace_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "openclaw-workspace-host"
  namespace  = kubernetes_namespace.openclaw.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/openclaw/workspace"
}

resource "kubernetes_persistent_volume_claim" "data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "openclaw-data-proxmox"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
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

## cc-config NFS volume removed — replaced by dotfiles repo clone in init container
## See init_container "install-dotfiles" in the deployment

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
        annotations = {
          "reloader.stakater.com/search" = "true"
        }
      }
      spec {
        service_account_name = kubernetes_service_account.openclaw.metadata[0].name

        # Init 0: fix /workspace ownership so node user can write
        init_container {
          name    = "fix-workspace-perms"
          image   = "busybox:1.37"
          command = ["sh", "-c", "chown 1000:1000 /workspace"]
          volume_mount {
            name       = "workspace"
            mount_path = "/workspace"
          }
        }

        # Init 1: copy openclaw.json from ConfigMap into writable NFS home
        init_container {
          name    = "copy-config"
          image   = "busybox:1.37"
          command = ["sh", "-c", "cp /config/openclaw.json /home/node/.openclaw/openclaw.json && chown 1000:1000 /home/node/.openclaw/openclaw.json"]
          volume_mount {
            name       = "openclaw-config"
            mount_path = "/config"
          }
          volume_mount {
            name       = "openclaw-home"
            mount_path = "/home/node/.openclaw"
          }
        }

        # Init 2 removed: install-dotfiles init container was cloning dotfiles
        # repo via git on every pod start, causing 200+ small NFS writes.
        # Dotfiles already exist on NFS at /home/node/.openclaw/dotfiles from
        # a previous clone. To update, run git pull manually or via CronJob.

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
            name  = "NODE_OPTIONS"
            value = "--max-old-space-size=1536"
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
            name = "MEMORY_API_KEY"
            value_from {
              secret_key_ref {
                name = "openclaw-secrets"
                key  = "claude_memory_api_key"
              }
            }
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
              memory = "2Gi"
            }
            requests = {
              cpu    = "100m"
              memory = "2Gi"
            }
          }
        }

        # Sidecar: playwright-mcp — headless browser for agents
        container {
          name  = "playwright-mcp"
          image = "docker.io/viktorbarzin/playwright-mcp:v1"
          args  = ["--headless", "--browser", "chromium", "--no-sandbox", "--port", "3000", "--host", "0.0.0.0"]
          port {
            container_port = 3000
          }
          resources {
            requests = {
              cpu    = "50m"
              memory = "256Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }

        # Sidecar: modelrelay — auto-routes to fastest healthy free model
        container {
          name  = "modelrelay"
          image = "docker.io/library/node:22-alpine"
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
            name = "NVIDIA_API_KEY"
            value_from {
              secret_key_ref {
                name = "openclaw-secrets"
                key  = "nvidia_api_key"
              }
            }
          }
          env {
            name = "OPENROUTER_API_KEY"
            value_from {
              secret_key_ref {
                name = "openclaw-secrets"
                key  = "openrouter_api_key"
              }
            }
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
              memory = "128Mi"
            }
          }
        }

        volume {
          name = "tools"
          persistent_volume_claim {
            claim_name = module.nfs_tools_host.claim_name
          }
        }
        volume {
          name = "openclaw-home"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.home_proxmox.metadata[0].name
          }
        }
        volume {
          name = "workspace"
          persistent_volume_claim {
            claim_name = module.nfs_workspace_host.claim_name
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data_proxmox.metadata[0].name
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
  dns_type        = "non-proxied"
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
                      FORGEJO_URL="http://forgejo.forgejo.svc.cluster.local" \
                      OPENCLAW_TOKEN="$OPENCLAW_TOKEN" \
                      OPENCLAW_URL="https://integrate.api.nvidia.com" \
                  bash /workspace/infra/scripts/task-processor.sh
              EOF
              ]

              env {
                name = "FORGEJO_TOKEN"
                value_from {
                  secret_key_ref {
                    name = "openclaw-secrets"
                    key  = "forgejo_api_token"
                  }
                }
              }
              env {
                name = "OPENCLAW_TOKEN"
                value_from {
                  secret_key_ref {
                    name = "openclaw-secrets"
                    key  = "nvidia_api_key"
                  }
                }
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

# --- OpenLobster: Multi-user Telegram AI assistant (trial) ---

resource "kubernetes_persistent_volume_claim" "openlobster_data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "openlobster-data-proxmox"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
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

resource "random_password" "openlobster_graphql_token" {
  length  = 32
  special = false
}

resource "kubernetes_deployment" "openlobster" {
  metadata {
    name      = "openlobster"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
    labels = {
      app  = "openlobster"
      tier = local.tiers.aux
    }
  }
  spec {
    strategy {
      type = "Recreate"
    }
    replicas = 0
    selector {
      match_labels = {
        app = "openlobster"
      }
    }
    template {
      metadata {
        labels = {
          app = "openlobster"
        }
      }
      spec {
        # node4 has corrupted containerd content store — avoid it
        affinity {
          node_affinity {
            required_during_scheduling_ignored_during_execution {
              node_selector_term {
                match_expressions {
                  key      = "kubernetes.io/hostname"
                  operator = "NotIn"
                  values   = ["k8s-node4"]
                }
              }
            }
          }
        }
        container {
          name  = "openlobster"
          image = "ghcr.io/neirth/openlobster/openlobster:latest"
          port {
            container_port = 8080
          }
          env {
            name  = "OPENLOBSTER_GRAPHQL_AUTH_TOKEN"
            value = random_password.openlobster_graphql_token.result
          }
          env {
            name = "OPENLOBSTER_PROVIDERS_ANTHROPIC_API_KEY"
            value_from {
              secret_key_ref {
                name = "openclaw-secrets"
                key  = "anthropic_api_key"
              }
            }
          }
          env {
            name  = "OPENLOBSTER_PROVIDERS_ANTHROPIC_MODEL"
            value = "claude-sonnet-4-20250514"
          }
          env {
            name = "OPENLOBSTER_CHANNELS_TELEGRAM_TOKEN"
            value_from {
              secret_key_ref {
                name = "openclaw-secrets"
                key  = "telegram_bot_token"
              }
            }
          }
          env {
            name  = "OPENLOBSTER_DATABASE_DRIVER"
            value = "sqlite"
          }
          env {
            name  = "OPENLOBSTER_DATABASE_DSN"
            value = "/app/data/openlobster.db"
          }
          env {
            name  = "OPENLOBSTER_AGENT_NAME"
            value = "Lobster"
          }
          env {
            name  = "OPENLOBSTER_MEMORY_BACKEND"
            value = "file"
          }
          volume_mount {
            name       = "openlobster-data"
            mount_path = "/app/data"
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
        volume {
          name = "openlobster-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.openlobster_data_proxmox.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].template[0].spec[0].dns_config] # KYVERNO_LIFECYCLE_V1
  }
}

resource "kubernetes_service" "openlobster" {
  metadata {
    name      = "openlobster"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
    labels = {
      app = "openlobster"
    }
  }
  spec {
    selector = {
      app = "openlobster"
    }
    port {
      port        = 80
      target_port = 8080
    }
  }
}

module "openlobster_ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.openclaw.metadata[0].name
  name            = "openlobster"
  tls_secret_name = var.tls_secret_name
  host            = "openlobster"
  port            = 80
  protected       = true
}
