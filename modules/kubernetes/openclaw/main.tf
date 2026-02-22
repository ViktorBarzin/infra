variable "tls_secret_name" {}
variable "tier" { type = string }
variable "ssh_key" {}
variable "gemini_api_key" { type = string }
variable "llama_api_key" { type = string }
variable "brave_api_key" { type = string }
variable "modal_api_key" { type = string }
variable "skill_secrets" { type = map(string) }

resource "kubernetes_namespace" "openclaw" {
  metadata {
    name = "openclaw"
    labels = {
      tier = var.tier
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
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
    "id_rsa" = var.ssh_key
  }
  type = "generic"
}

resource "kubernetes_config_map" "git_crypt_key" {
  metadata {
    name      = "git-crypt-key"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
  }
  data = {
    "key" = filebase64("${path.root}/.git/git-crypt/keys/default")
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
        bind           = "lan"
        trustedProxies = ["10.0.0.0/8"]
        controlUi = {
          dangerouslyDisableDeviceAuth = true
        }
      }
      agents = {
        defaults = {
          contextTokens     = 1000000
          bootstrapMaxChars = 30000
          model = {
            primary   = "modal/zai-org/GLM-5-FP8"
            fallbacks = ["gemini/gemini-2.5-flash", "llama-as-openai/Llama-3.3-70B-Instruct"]
          }
          models = {
            "modal/zai-org/GLM-5-FP8"                            = { streaming = false }
            "gemini/gemini-2.5-flash"                            = {}
            "llama-as-openai/Llama-3.3-70B-Instruct"             = {}
            "llama-as-openai/Llama-4-Scout-17B-16E-Instruct-FP8" = {}
          }
        }
      }
      tools = {
        profile = "full"
        deny    = ["sessions_spawn", "sessions_list", "sessions_history", "sessions_send", "subagents", "browser"]
        exec = {
          host        = "sandbox"
          security    = "full"
          ask         = "off"
          pathPrepend = ["/tools", "/workspace/infra"]
        }
        web = {
          search = {
            enabled    = true
            provider   = "brave"
            apiKey     = var.brave_api_key
            maxResults = 5
          }
          fetch = {
            enabled        = true
            maxChars       = 50000
            timeoutSeconds = 30
          }
        }
      }
      models = {
        mode = "merge"
        providers = {
          modal = {
            baseUrl = "https://api.us-west-2.modal.direct/v1"
            api     = "openai-completions"
            apiKey  = var.modal_api_key
            models = [
              { id = "zai-org/GLM-5-FP8", name = "GLM-5", reasoning = false, input = ["text"], contextWindow = 128000, maxTokens = 8192, cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0 } },
            ]
          }
          gemini = {
            baseUrl = "https://generativelanguage.googleapis.com/v1beta"
            api     = "google-generative-ai"
            apiKey  = var.gemini_api_key
            models = [
              { id = "gemini-2.5-flash", name = "gemini-2.5-flash", reasoning = true, input = ["text", "image"], contextWindow = 1048576, maxTokens = 65536, cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0 } },
            ]
          }
          ollama = {
            baseUrl = "http://ollama.ollama.svc.cluster.local:11434/v1"
            api     = "openai-completions"
            apiKey  = "ollama"
            models = [
              { id = "qwen2.5-coder:14b", name = "qwen2.5-coder:14b", reasoning = false, input = ["text"], contextWindow = 128000, maxTokens = 8192, cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0 } },
              { id = "qwen2.5:14b", name = "qwen2.5:14b", reasoning = false, input = ["text"], contextWindow = 128000, maxTokens = 8192, cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0 } },
              { id = "deepseek-r1:14b", name = "deepseek-r1:14b", reasoning = true, input = ["text"], contextWindow = 128000, maxTokens = 8192, cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0 } },
            ]
          }
          llama-as-openai = {
            baseUrl = "https://api.llama.com/compat/v1"
            apiKey  = var.llama_api_key
            api     = "openai-completions"
            models = [
              { id = "Llama-3.3-70B-Instruct", name = "Llama-3.3-70B-Instruct", reasoning = false, input = ["text"], contextWindow = 128000, maxTokens = 8192, cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0 } },
              { id = "Llama-4-Scout-17B-16E-Instruct-FP8", name = "Llama-4-Scout-17B-16E-Instruct-FP8", reasoning = false, input = ["text"], contextWindow = 200000, maxTokens = 8192, cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0 } },
              { id = "Llama-4-Maverick-17B-128E-Instruct-FP8", name = "Llama-4-Maverick-17B-128E-Instruct-FP8", reasoning = false, input = ["text"], contextWindow = 200000, maxTokens = 8192, cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0 } },
            ]
          }
        }
      }
    })
  }
}

resource "random_password" "gateway_token" {
  length  = 32
  special = false
}

resource "kubernetes_deployment" "openclaw" {
  metadata {
    name      = "openclaw"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
    labels = {
      app  = "openclaw"
      tier = var.tier
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

        # Init container: Download tools + clone repo + terraform init (parallelized)
        init_container {
          name  = "setup"
          image = "alpine:3.20"
          command = ["sh", "-c", <<-EOF
            set -e
            apk add --no-cache curl unzip git-crypt openssh-client git bash

            # Install pip and Python packages for skills
            python3 -m ensurepip 2>/dev/null || apk add --no-cache py3-pip
            pip3 install --break-system-packages --target=/tools/python-libs requests caldav icalendar uptime-kuma-api

            # Copy OpenClaw config to writable home dir
            cp /openclaw-config-src/openclaw.json /openclaw-home/openclaw.json

            # Setup SSH key
            mkdir -p /root/.ssh
            cp /ssh/id_rsa /root/.ssh/id_rsa
            chmod 600 /root/.ssh/id_rsa
            ssh-keyscan github.com >> /root/.ssh/known_hosts 2>/dev/null

            # --- Run downloads and clone in parallel ---
            # kubectl
            (curl -sL --retry 3 --retry-delay 5 "https://dl.k8s.io/release/v1.34.2/bin/linux/amd64/kubectl" -o /tools/kubectl && chmod +x /tools/kubectl) &
            PID_KUBECTL=$!

            # terraform
            (curl -sL --retry 3 --retry-delay 5 "https://releases.hashicorp.com/terraform/1.14.5/terraform_1.14.5_linux_amd64.zip" -o /tmp/tf.zip && unzip -q /tmp/tf.zip -d /tools && chmod +x /tools/terraform && rm /tmp/tf.zip) &
            PID_TF=$!

            # git-crypt (already installed via apk)
            cp /usr/bin/git-crypt /tools/git-crypt

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
            wait $PID_GIT || { echo "git clone/pull failed"; exit 1; }

            # Unlock git-crypt (needs clone done)
            cd /workspace/infra
            echo "$GIT_CRYPT_KEY" | base64 -d > /tmp/git-crypt-key
            git-crypt unlock /tmp/git-crypt-key || true
            rm /tmp/git-crypt-key

            # Mark repo as safe for the node user (different UID from init container)
            git config --global --add safe.directory /workspace/infra
            cp /root/.gitconfig /openclaw-home/.gitconfig 2>/dev/null || true

            # Symlink Claude skills into OpenClaw skills directory
            ln -sfn /workspace/infra/.claude/skills /openclaw-home/skills

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

            # Terraform init (needs terraform + clone done)
            wait $PID_TF || { echo "terraform download failed"; exit 1; }
            /tools/terraform init
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
        }

        # Main container: OpenClaw
        container {
          name    = "openclaw"
          image   = "ghcr.io/openclaw/openclaw:2026.2.9"
          command = ["node", "openclaw.mjs", "gateway", "--allow-unconfigured", "--bind", "lan"]
          port {
            container_port = 18789
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
          env {
            name  = "GEMINI_API_KEY"
            value = var.gemini_api_key
          }
          # Skill secrets - Home Assistant
          env {
            name  = "HOME_ASSISTANT_URL"
            value = "https://ha-london.viktorbarzin.me"
          }
          env {
            name  = "HOME_ASSISTANT_TOKEN"
            value = var.skill_secrets["home_assistant_token"]
          }
          env {
            name  = "HOME_ASSISTANT_SOFIA_URL"
            value = "https://ha-sofia.viktorbarzin.me"
          }
          env {
            name  = "HOME_ASSISTANT_SOFIA_TOKEN"
            value = var.skill_secrets["home_assistant_sofia_token"]
          }
          # Skill secrets - Uptime Kuma
          env {
            name  = "UPTIME_KUMA_PASSWORD"
            value = var.skill_secrets["uptime_kuma_password"]
          }
          # Skill secrets - Slack
          env {
            name  = "SLACK_WEBHOOK_URL"
            value = var.skill_secrets["slack_webhook"]
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
              memory = "4Gi"
            }
            requests = {
              memory = "256Mi"
            }
          }
        }

        volume {
          name = "tools"
          empty_dir {}
        }
        volume {
          name = "openclaw-home"
          empty_dir {}
        }
        volume {
          name = "workspace"
          nfs {
            server = "10.0.10.15"
            path   = "/mnt/main/openclaw/workspace"
          }
        }
        volume {
          name = "data"
          nfs {
            server = "10.0.10.15"
            path   = "/mnt/main/openclaw/data"
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
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.openclaw.metadata[0].name
  name            = "openclaw"
  tls_secret_name = var.tls_secret_name
  port            = 80
  protected       = true
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
      tier = var.tier
    }
  }
  spec {
    schedule                      = "*/30 * * * *"
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
                  memory = "128Mi"
                }
              }
            }
          }
        }
      }
    }
  }
}
