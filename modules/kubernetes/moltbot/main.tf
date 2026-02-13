variable "tls_secret_name" {}
variable "tier" { type = string }
variable "ssh_key" {}

resource "kubernetes_namespace" "moltbot" {
  metadata {
    name = "moltbot"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.moltbot.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_service_account" "moltbot" {
  metadata {
    name      = "moltbot"
    namespace = kubernetes_namespace.moltbot.metadata[0].name
  }
}

resource "kubernetes_cluster_role_binding" "moltbot" {
  metadata {
    name = "moltbot-cluster-admin"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.moltbot.metadata[0].name
    namespace = kubernetes_namespace.moltbot.metadata[0].name
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
    namespace = kubernetes_namespace.moltbot.metadata[0].name
  }
  data = {
    "id_rsa" = var.ssh_key
  }
  type = "generic"
}

resource "kubernetes_config_map" "git_crypt_key" {
  metadata {
    name      = "git-crypt-key"
    namespace = kubernetes_namespace.moltbot.metadata[0].name
  }
  data = {
    "key" = filebase64("${path.root}/.git/git-crypt/keys/default")
  }
}

resource "kubernetes_config_map" "openclaw_config" {
  metadata {
    name      = "openclaw-config"
    namespace = kubernetes_namespace.moltbot.metadata[0].name
  }
  data = {
    "openclaw.json" = jsonencode({
      gateway = {
        bind = "lan"
        controlUi = {
          dangerouslyDisableDeviceAuth = true
          allowedOrigins               = ["https://moltbot.viktorbarzin.me"]
        }
      }
      models = {
        providers = {
          ollama = {
            baseUrl = "http://ollama.ollama.svc.cluster.local:11434/v1"
            apiKey  = "ollama-local"
            api     = "openai-completions"
            models  = [
              { id = "qwen2.5:14b", name = "Qwen 2.5 14B" },
              { id = "qwen2.5-coder:14b", name = "Qwen 2.5 Coder 14B" },
              { id = "deepseek-r1:14b", name = "DeepSeek R1 14B" },
              { id = "qwen2.5:7b", name = "Qwen 2.5 7B" },
              { id = "qwen2.5-coder:7b", name = "Qwen 2.5 Coder 7B" },
              { id = "gemma2:9b", name = "Gemma 2 9B" },
              { id = "llama3.1:latest", name = "Llama 3.1 8B" },
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

resource "kubernetes_deployment" "moltbot" {
  metadata {
    name      = "moltbot"
    namespace = kubernetes_namespace.moltbot.metadata[0].name
    labels = {
      app  = "moltbot"
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
        app = "moltbot"
      }
    }
    template {
      metadata {
        labels = {
          app = "moltbot"
        }
      }
      spec {
        service_account_name = kubernetes_service_account.moltbot.metadata[0].name

        # Init container 1: Download kubectl, terraform, git-crypt to /tools
        init_container {
          name  = "install-tools"
          image = "alpine:3.20"
          command = ["sh", "-c", <<-EOF
            set -e
            apk add --no-cache curl unzip git-crypt
            # kubectl
            curl -sL "https://dl.k8s.io/release/v1.34.2/bin/linux/amd64/kubectl" -o /tools/kubectl
            chmod +x /tools/kubectl
            # terraform
            curl -sL "https://releases.hashicorp.com/terraform/1.12.1/terraform_1.12.1_linux_amd64.zip" -o /tmp/tf.zip
            unzip /tmp/tf.zip -d /tools
            chmod +x /tools/terraform
            # git-crypt (copy from apk install)
            cp /usr/bin/git-crypt /tools/git-crypt
          EOF
          ]
          volume_mount {
            name       = "tools"
            mount_path = "/tools"
          }
        }

        # Init container 2: Clone infra repo, unlock git-crypt, run terraform init
        init_container {
          name  = "clone-repo"
          image = "alpine/git"
          command = ["sh", "-c", <<-EOF
            set -e
            apk add --no-cache openssh-client bash git-crypt
            export PATH="/tools:$PATH"
            # Copy OpenClaw config to writable home dir
            cp /openclaw-config-src/openclaw.json /openclaw-home/openclaw.json
            # Setup SSH key
            mkdir -p /root/.ssh
            cp /ssh/id_rsa /root/.ssh/id_rsa
            chmod 600 /root/.ssh/id_rsa
            ssh-keyscan github.com >> /root/.ssh/known_hosts 2>/dev/null
            # Clone repo if not already present
            if [ ! -d /workspace/infra/.git ]; then
              git clone git@github.com:ViktorBarzin/infra.git /workspace/infra
            else
              cd /workspace/infra && git pull --ff-only || true
            fi
            cd /workspace/infra
            # Unlock git-crypt
            echo "$GIT_CRYPT_KEY" | base64 -d > /tmp/git-crypt-key
            git-crypt unlock /tmp/git-crypt-key || true
            rm /tmp/git-crypt-key
            # Terraform init
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
          name  = "moltbot"
          image = "ghcr.io/openclaw/openclaw:latest"
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
            path   = "/mnt/main/moltbot/workspace"
          }
        }
        volume {
          name = "data"
          nfs {
            server = "10.0.10.15"
            path   = "/mnt/main/moltbot/data"
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

resource "kubernetes_service" "moltbot" {
  metadata {
    name      = "moltbot"
    namespace = kubernetes_namespace.moltbot.metadata[0].name
    labels = {
      app = "moltbot"
    }
  }
  spec {
    selector = {
      app = "moltbot"
    }
    port {
      port        = 80
      target_port = 18789
    }
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.moltbot.metadata[0].name
  name            = "moltbot"
  tls_secret_name = var.tls_secret_name
  port            = 80
  protected       = true
}
