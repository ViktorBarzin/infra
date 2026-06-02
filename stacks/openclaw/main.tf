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
      "keel.sh/enrolled"                      = "true"
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
            # 2026-05-22: switched primary to nim/meta/llama-3.1-70b-instruct.
            # Verified end-to-end with tool calls (sub-second responses,
            # proper tool_calls in API response). Auth audit on this date:
            #   - openai-codex OAuth: EXPIRED (ancaelena98@gmail.com,
            #     ChatGPT Plus). Re-auth requires interactive TTY:
            #       kubectl -n openclaw exec -it $(kubectl -n openclaw \
            #         get pods -l app=openclaw -o jsonpath='{.items[0].metadata.name}') \
            #         -c openclaw -- node /app/openclaw.mjs models auth \
            #         login --provider openai-codex
            #   - secret/openclaw → openai_api_key (sk-svcacct…):
            #     insufficient_quota (billing exhausted)
            #   - openrouter_api_key: "Key limit exceeded"
            #   - llama_api_key: region-blocked
            #   - anthropic_api_key: sk-ant-oat-… (OAuth refresh token,
            #     NOT a real x-api-key — won't auth)
            #   - nvidia_api_key: WORKS. nim/meta/llama-3.1-70b-instruct
            #     and nim/meta/llama-4-maverick-17b-128e-instruct both
            #     tool-call reliably.
            # Keep codex as a fallback so it auto-promotes once
            # re-authed; modelrelay last because it routes to a
            # small model that hallucinates instead of tool-calling.
            primary   = "nim/meta/llama-3.1-70b-instruct"
            fallbacks = ["nim/meta/llama-4-maverick-17b-128e-instruct", "openai-codex/gpt-5.4-mini", "modelrelay/auto-fastest"]
          }
          models = {
            "modelrelay/auto-fastest"                                = {}
            "nim/deepseek-ai/deepseek-v3.2"                          = {}
            "nim/qwen/qwen3.5-397b-a17b"                             = {}
            "nim/mistralai/mistral-large-3-675b-instruct-2512"       = {}
            "nim/qwen/qwen3-coder-480b-a35b-instruct"                = {}
            "nim/nvidia/llama-3.1-nemotron-ultra-253b-v1"            = {}
            "nim/z-ai/glm5"                                          = {}
            "nim/meta/llama-3.1-70b-instruct"                        = {}
            "nim/meta/llama-4-maverick-17b-128e-instruct"            = {}
            "llama-as-openai/Llama-4-Maverick-17B-128E-Instruct-FP8" = {}
            "llama-as-openai/Llama-4-Scout-17B-16E-Instruct-FP8"     = {}
            "openrouter/stepfun/step-3.5-flash:free"                 = {}
            "openrouter/arcee-ai/trinity-large-preview:free"         = {}
            "openai-codex/gpt-5.4-mini"                              = {}
            "openai-codex/gpt-5.5"                                   = {}
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
        allow = ["memory-core", "recruiter-api"]
        slots = { memory = "memory-core" }
        load = {
          # /app/extensions is the legacy bundled-plugins path; OpenClaw
          # already loads bundled plugins natively (doctor warning).
          paths = ["/home/node/.openclaw/extensions"]
        }
      }
      # Note: mcp.servers is configured via `openclaw mcp set` in the main
      # container startup command (see below) rather than in this ConfigMap.
      # OpenClaw's `doctor --fix` (which runs on every pod start) strips
      # bulk-loaded mcp blocks from openclaw.json, but preserves CLI-set
      # entries. The CLI is the canonical writer.
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
              { id = "meta/llama-3.1-70b-instruct", name = "Llama 3.1 70B Instruct", reasoning = false, input = ["text"], contextWindow = 128000, maxTokens = 16384, cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0 } },
              { id = "meta/llama-4-maverick-17b-128e-instruct", name = "Llama 4 Maverick (NIM)", reasoning = false, input = ["text"], contextWindow = 1000000, maxTokens = 16384, cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0 } },
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

# Prometheus exporter script — read by the openclaw-exporter sidecar.
# Stdlib-only Python so no pip install at startup. Reads sessions JSONL +
# auth-profiles.json from the NFS-backed openclaw home volume (mounted ro).
resource "kubernetes_config_map" "openclaw_exporter" {
  metadata {
    name      = "openclaw-exporter"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
  }
  data = {
    "exporter.py" = file("${path.module}/files/exporter.py")
  }
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
      "resize.topolvm.io/threshold"     = "10%"
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
  lifecycle {
    # The autoresizer expands requests.storage up to storage_limit and
    # PVCs can't shrink. Without this, every TF apply tries to revert
    # to the spec value, K8s rejects the shrink, and the PVC ends up
    # in Terminating-but-in-use limbo.
    ignore_changes = [spec[0].resources[0].requests]
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
      "resize.topolvm.io/threshold"     = "10%"
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
  lifecycle {
    # The autoresizer expands requests.storage up to storage_limit and
    # PVCs can't shrink. Without this, every TF apply tries to revert
    # to the spec value, K8s rejects the shrink, and the PVC ends up
    # in Terminating-but-in-use limbo.
    ignore_changes = [spec[0].resources[0].requests]
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
          # Prometheus auto-discovers pods with these annotations.
          # Scraped by the openclaw-exporter sidecar — exposes /metrics on :9099.
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = "9099"
          "prometheus.io/path"   = "/metrics"
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

        # Init 1b: regenerate kubeconfig pointing at the projected SA tokenFile
        # so kubectl always reads the fresh, kubelet-rotated token. Without
        # this the previously-baked kubeconfig retains a SA token bound to a
        # long-dead pod and kubectl returns "must be logged in to the server".
        init_container {
          name  = "setup-kubeconfig"
          image = "busybox:1.37"
          command = ["sh", "-c", <<-EOT
            cat > /home/node/.openclaw/kubeconfig <<'KUBECONFIG_EOF'
            apiVersion: v1
            kind: Config
            clusters:
            - cluster:
                certificate-authority: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
                server: https://kubernetes.default.svc
              name: in-cluster
            contexts:
            - context:
                cluster: in-cluster
                user: openclaw
                namespace: openclaw
              name: in-cluster
            current-context: in-cluster
            users:
            - name: openclaw
              user:
                tokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
            KUBECONFIG_EOF
            chown 1000:1000 /home/node/.openclaw/kubeconfig
            chmod 0644 /home/node/.openclaw/kubeconfig
          EOT
          ]
          volume_mount {
            name       = "openclaw-home"
            mount_path = "/home/node/.openclaw"
          }
        }

        # Init 2 removed: install-dotfiles init container was cloning dotfiles
        # repo via git on every pod start, causing 200+ small NFS writes.
        # Dotfiles already exist on NFS at /home/node/.openclaw/dotfiles from
        # a previous clone. To update, run git pull manually or via CronJob.

        # Init 3: install the recruiter-api OpenClaw plugin from the
        # recruiter-responder image into NFS extensions/. Plugin lifecycle
        # is coupled to the recruiter-responder image tag — bumping that
        # tag re-installs the plugin on next openclaw pod restart.
        init_container {
          name  = "install-recruiter-plugin"
          image = "forgejo.viktorbarzin.me/viktor/recruiter-responder:latest"
          command = ["sh", "-c", <<-EOT
            set -eu
            mkdir -p /home/node/.openclaw/extensions/recruiter-api
            cp -r /app/openclaw-plugin/. /home/node/.openclaw/extensions/recruiter-api/
            chown -R 1000:1000 /home/node/.openclaw/extensions/recruiter-api
            echo "recruiter-api plugin installed at /home/node/.openclaw/extensions/recruiter-api"
            ls -la /home/node/.openclaw/extensions/recruiter-api
          EOT
          ]
          # /home/node/.openclaw is uid 1000 on NFS; recruiter-responder image
          # otherwise drops to uid 10001 which can't write or chown. Run as
          # root so mkdir + chown succeed.
          security_context {
            run_as_user = 0
          }
          volume_mount {
            name       = "openclaw-home"
            mount_path = "/home/node/.openclaw"
          }
          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { memory = "128Mi" }
          }
        }

        # Init 4: install host-tools bundle (ssh, vault, jq, ripgrep, tmux, …)
        # into /tools/host-tools/ so the in-pod agent reaches CLI parity
        # with the dev VM. Upstream OpenClaw image is minimal Debian
        # bookworm running as uid 1000 — can't apt-install at runtime.
        # Idempotent via marker file; bump suffix to force reinstall.
        # See docs/plans/2026-05-22-openclaw-devvm-access-design.md.
        init_container {
          name  = "install-host-tools"
          image = "debian:bookworm-slim"
          command = ["bash", "-c", <<-EOT
            set -euo pipefail
            DEST=/tools/host-tools
            MARKER="$DEST/.installed-v1"
            if [ -f "$MARKER" ]; then
              echo "host-tools v1 already installed (skipping)"
              exit 0
            fi
            echo "installing host-tools v1 ..."
            rm -rf "$DEST"
            mkdir -p "$DEST/root" "$DEST/bin"

            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            # debian:bookworm-slim doesn't ship wget/unzip; install
            # transiently into this init container's filesystem so we
            # can download the static binaries below.
            apt-get install -y --no-install-recommends wget unzip ca-certificates

            # NOTE: we deliberately do NOT pass --no-install-recommends to
            # the download step. ssh links against libgssapi-krb5-2 which
            # is a hard Depends but its transitive deps (libkrb5-3 etc.)
            # need to come along too. The bundle is a self-contained
            # /usr-like tree that the openclaw container can use via
            # LD_LIBRARY_PATH, so missing deps = broken binaries.
            APT_PKGS="openssh-client dnsutils iputils-ping wget gnupg jq ripgrep fd-find ncdu htop strace tcpdump tmux unzip ca-certificates"
            apt-get install -y --download-only $APT_PKGS

            for d in /var/cache/apt/archives/*.deb; do
              dpkg-deb -x "$d" "$DEST/root/"
            done

            VAULT_VER=1.18.3
            YQ_VER=v4.44.3
            wget -qO /tmp/vault.zip \
              "https://releases.hashicorp.com/vault/$${VAULT_VER}/vault_$${VAULT_VER}_linux_amd64.zip"
            unzip -o /tmp/vault.zip vault -d "$DEST/bin/"
            chmod +x "$DEST/bin/vault"
            wget -qO "$DEST/bin/yq" \
              "https://github.com/mikefarah/yq/releases/download/$${YQ_VER}/yq_linux_amd64"
            chmod +x "$DEST/bin/yq"

            # Smoke test — fail init if any bundled binary has unresolved
            # shared-lib deps, so glibc / shared-lib drift surfaces at
            # deploy time. We don't run --version because flag support
            # varies (older scp returns non-zero, ping/nslookup use weird
            # conventions). ldd is the reliable signal: if any "not
            # found" appears, the binary won't load when called.
            # LD_LIBRARY_PATH points ld.so at the bundled libs (the
            # openclaw main container sets the same env).
            export PATH="$DEST/root/usr/bin:$DEST/root/usr/sbin:$DEST/root/bin:$DEST/root/sbin:$DEST/bin:$PATH"
            export LD_LIBRARY_PATH="$DEST/root/usr/lib/x86_64-linux-gnu:$DEST/root/lib/x86_64-linux-gnu"
            for t in ssh scp ssh-keyscan dig host nslookup ping wget gpg jq rg fdfind tmux vault yq; do
              bin=$(command -v "$t" 2>/dev/null) || { echo "FAIL: $t not on PATH"; exit 1; }
              if ldd "$bin" 2>&1 | grep -q "not found"; then
                echo "FAIL: $t has unresolved shared libs:"
                ldd "$bin"
                exit 1
              fi
              echo "OK: $t"
            done

            chown -R 1000:1000 "$DEST"
            touch "$MARKER"
            echo "host-tools v1 install complete ($(du -sh "$DEST" | cut -f1))"
          EOT
          ]
          volume_mount {
            name       = "tools"
            mount_path = "/tools"
          }
          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { memory = "512Mi" }
          }
        }

        # Init 5: write /home/node/.openclaw/.ssh/{id_rsa,config,known_hosts}
        # so the agent can `ssh devvm` without device-trust prompts. The
        # main container symlinks /home/node/.ssh → here at startup so
        # the ssh client picks it up via $HOME/.ssh. Installs
        # openssh-client transiently into this init container so
        # ssh-keyscan works without LD_LIBRARY_PATH gymnastics.
        init_container {
          name  = "setup-ssh-config"
          image = "debian:bookworm-slim"
          command = ["bash", "-c", <<-EOT
            set -euo pipefail
            SSH=/home/node/.openclaw/.ssh
            MARKER="$SSH/.configured-v1"
            if [ -f "$MARKER" ]; then
              echo "ssh-config v1 already set up (skipping)"
              exit 0
            fi
            echo "installing openssh-client for ssh-keyscan ..."
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y --no-install-recommends openssh-client >/dev/null

            echo "configuring ssh ..."
            mkdir -p "$SSH"

            # Copy the secret-mounted private key into ~/.ssh with 0600 —
            # the secret's tmpfs mount has wider perms (1777 + symlinks)
            # that openssh refuses.
            cp /ssh/id_rsa "$SSH/id_rsa"
            chmod 0600 "$SSH/id_rsa"

            cat > "$SSH/config" <<'SSH_EOF'
            Host devvm
              HostName 10.0.10.10
              User wizard
              IdentityFile ~/.ssh/id_rsa
              UserKnownHostsFile ~/.ssh/known_hosts
              StrictHostKeyChecking yes
            SSH_EOF
            chmod 0600 "$SSH/config"

            ssh-keyscan -H 10.0.10.10 > "$SSH/known_hosts" 2>/tmp/keyscan.err
            if [ ! -s "$SSH/known_hosts" ]; then
              echo "ssh-keyscan produced empty known_hosts; stderr:"
              cat /tmp/keyscan.err
              exit 1
            fi
            chmod 0644 "$SSH/known_hosts"

            chown -R 1000:1000 "$SSH"
            touch "$MARKER"
            echo "ssh-config v1 set up"
          EOT
          ]
          volume_mount {
            name       = "openclaw-home"
            mount_path = "/home/node/.openclaw"
          }
          volume_mount {
            name       = "ssh-key"
            mount_path = "/ssh"
          }
          resources {
            requests = { cpu = "50m", memory = "64Mi" }
            limits   = { memory = "256Mi" }
          }
        }

        # Init 6: seed the "know → ask devvm → save" learning loop into
        # FIVE places so it's engrained at the identity level, not just
        # buried as workflow advice:
        #
        # 1. /workspace/SOUL.md — read every session per AGENTS.md, this
        #    is the agent's identity. A marker-delimited section there
        #    says "learning is who you are" (single short truth, no
        #    procedural detail).
        # 2. /workspace/TOOLS.md — full how-to, inserted at the TOP of
        #    the file so the agent sees it first when loading bootstrap.
        # 3. /workspace/memory/projects/openclaw-runtime/devvm-fallback.md
        #    — indexed by memory-core (memory_recall surfaces it).
        # 4. /workspace/memory/projects/openclaw-learned/ — durable cache
        #    of recipes the agent has saved. INDEX.md is the first thing
        #    checked on any task (Step 1 of the flow).
        # 5. /home/node/.openclaw/cc-skills/learn-from-tasks/SKILL.md —
        #    formal skill with the triage logic.
        # All marker-delimited (v4) so user edits outside markers
        # survive future pod restarts. The four artifacts that ARE
        # marker-managed reinforce the same rule from different angles:
        # identity (SOUL), how (TOOLS), memory-search (memory note),
        # entry-point (skill).
        init_container {
          name  = "seed-devvm-memory-note"
          image = "busybox:1.37"
          command = ["sh", "-c", <<-EOT
            set -eu

            # ---- 1. Memory note (memory-core searchable) ----------------
            DIR=/workspace/memory/projects/openclaw-runtime
            mkdir -p "$DIR"
            cat > "$DIR/devvm-fallback.md" <<'NOTE_EOF'
            # The learning loop — applies to EVERY task

            **The flow: know → ask devvm → (rarely) try yourself. Then
            save what you learned, always.** This is not optional and
            not specific to any domain — it's how you compound. Every
            task that ends with a saved recipe makes future-you
            stronger. Every task that doesn't is a wasted lesson.

            ## The flow

            1. **Know?** `memory_recall "<topic>"` and check
               `/workspace/memory/projects/openclaw-learned/INDEX.md`.
               If yes, use it.
            2. **Don't know?** Default to `ssh devvm` and ask claude.
               Don't brute-force. Most tasks are solvable there.
            3. **Devvm can't either?** (rare) Try in-pod, be honest
               about the risk, save anything you discover.

            ## The save (mandatory, every non-trivial task)

            After ANY task — calendar, container debugging, vault
            lookup, posting to Slack, parsing a log, whatever — pause
            and save the recipe to
            `/workspace/memory/projects/openclaw-learned/`:

            - Script  → scripts/<task>.md
            - Knowledge → knowledge/<topic>.md
            - Credential → credentials/<name>.md  **Vault pointer
              only, never the value**

            Update INDEX.md so the next session sees it.

            ## SSH cheatsheet

                ssh devvm 'vault kv get -field=KEY secret/PATH'
                ssh devvm 'claude -p "your prompt"'

                # async (>2 min) — survives pod restart
                ssh devvm openclaw-task new <id> "<command>"
                ssh devvm openclaw-task capture / log / status / kill
            NOTE_EOF
            chown -R 1000:1000 "$DIR"

            # ---- 2. SOUL.md identity-level rule -------------------------
            SOUL=/workspace/SOUL.md
            if [ -f "$SOUL" ]; then
              awk '
                $0 == "<!-- BEGIN openclaw-learning-soul v1 -->" { skip=1; next }
                $0 == "<!-- END openclaw-learning-soul v1 -->"   { skip=0; next }
                !skip { print }
              ' "$SOUL" > "$SOUL.tmp"

              # Insert before "## Boundaries" if present, else append.
              if grep -q "^## Boundaries" "$SOUL.tmp"; then
                awk '
                  /^## Boundaries$/ && !done {
                    print "<!-- BEGIN openclaw-learning-soul v1 -->"
                    print "**Learning is your identity.** Every task — anything anyone asks you to do — is also a learning opportunity. The job is not just to answer; it is to come back to the next person (or future-you) smarter than you were. When you figure out how to do something, save the recipe under /workspace/memory/projects/openclaw-learned/. When you needed devvm to figure it out, save what devvm taught you. The point is compounding: every saved learning makes the next task faster, and over time you become independent. See TOOLS.md and the `learn-from-tasks` skill for the protocol."
                    print "<!-- END openclaw-learning-soul v1 -->"
                    print ""
                    done=1
                  }
                  { print }
                ' "$SOUL.tmp" > "$SOUL.new"
              else
                cat "$SOUL.tmp" > "$SOUL.new"
                cat >> "$SOUL.new" <<'SOUL_EOF'

            <!-- BEGIN openclaw-learning-soul v1 -->
            **Learning is your identity.** Every task is a learning opportunity. Save what you figure out under /workspace/memory/projects/openclaw-learned/ so future-you is stronger. See TOOLS.md and the `learn-from-tasks` skill.
            <!-- END openclaw-learning-soul v1 -->
            SOUL_EOF
              fi
              mv "$SOUL.new" "$SOUL"
              rm -f "$SOUL.tmp"
              chown 1000:1000 "$SOUL"
            fi

            # ---- 3. TOOLS.md flow section, INSERTED AT TOP --------------
            TOOLS=/workspace/TOOLS.md
            touch "$TOOLS"
            # Strip prior versions (v1, v2, v3, v4) before re-inserting v4.
            # User edits outside the markers always survive.
            awk '
              /^<!-- BEGIN openclaw-devvm-section v[1-9] -->$/ { skip=1; next }
              /^<!-- END openclaw-devvm-section v[1-9] -->$/   { skip=0; next }
              !skip { print }
            ' "$TOOLS" > "$TOOLS.stripped"

            # Build the v4 section in /tmp, then insert near the top.
            cat > /tmp/devvm-section.md <<'TOOLS_EOF'
            <!-- BEGIN openclaw-devvm-section v4 -->
            ## THE FLOW — run this on EVERY task. Not just hard ones.

            This is universal. Same triage whether the user asks "what's
            on my calendar today?", "restart frigate", "find disk usage
            on node3", "summarise the inbox", or "deploy a new service".
            **Don't brute-force.** Don't say "I can't" until you've done
            steps 1-2. Most tasks are solvable.

            ```
                          ┌────────────────────────┐
            new task ────▶│ 1. Do I KNOW how?       │
                          │  memory_recall +        │
                          │  /workspace/memory/     │
                          │  projects/openclaw-     │
                          │  learned/INDEX.md       │
                          └────────────┬───────────┘
                                       │
                          yes ◀────────┴────────▶ no
                           │                       │
                           ▼                       ▼
                       Just do it.    ┌──────────────────────────┐
                                      │ 2. Ask claude on devvm:  │
                                      │  - can you do this?      │
                                      │  - if yes, do it AND     │
                                      │    share the recipe +    │
                                      │    credentials needed    │
                                      └────────────┬─────────────┘
                                                   │
                                       yes ◀───────┴───────▶ no
                                        │                    │
                                        ▼                    ▼
                              Devvm-claude does it.   3. (RARE) Let me try
                              SAVE the recipe to       in-pod. Most likely
                              openclaw-learned         I will fail; that's
                              (vault pointer for       OK — that's the
                              credentials).            point.
            ```

            **The save is not optional.** Every non-trivial task —
            success OR partial fail — ends with a row in
            `openclaw-learned/INDEX.md` and a markdown file with the
            recipe. The 2 minutes you spend saving now turn future-you
            into the agent who never has to ask again. This compounds.

            ## Step 1 — KNOW?

            Two checks, both fast:

                node /app/openclaw.mjs memory recall "<topic keywords>"
                cat /workspace/memory/projects/openclaw-learned/INDEX.md

            If a row matches, open the file and use it. Don't re-ask.

            ## Step 2 — ASK DEVVM (the default when you don't know)

            Use this prompt shape — explicitly ask for the recipe, not
            just the answer:

                ssh devvm 'claude -p --dangerously-skip-permissions \
                  "I am the openclaw agent. I need to do X (give context). \
                   Can you do this? If yes: do it now, then tell me 1) the \
                   exact commands I would run on my own next time, and 2) \
                   what credentials/paths I need (give Vault paths, NOT \
                   values). I will save your answer."'

            For work that takes more than ~2 minutes, dispatch async so
            the session survives this pod restarting:

                ssh devvm openclaw-task new <id> "<command>"
                ssh devvm openclaw-task capture <id>

            ## Step 3 — TRY IN-POD (rare)

            Only when devvm-claude says it can't. Be honest with the
            user about the uncertainty. If you DO find a way, save it
            just like Step 2.

            ## The save (do this on every non-trivial task)

            All learnings live under
            `/workspace/memory/projects/openclaw-learned/` (memory-core
            indexes this path; `memory_recall` surfaces it).

            - **Script / recipe** → `scripts/<task>.md`
              Inline a fenced code block. Header: WHAT, WHEN learned,
              HOW (verbatim devvm prompt or "self"), SOURCE (Vault path
              if a credential is involved).
            - **Knowledge** (decisions, paths, gotchas, conventions) →
              `knowledge/<topic>.md`
            - **Credential POINTER** → `credentials/<name>.md` —
              **NEVER stores the value.** Documents the Vault path +
              field + fetch command + consumer + rotation expectations.

            Then add a row to `openclaw-learned/INDEX.md`.

            ## devvm — wizard@10.0.10.10 (pre-wired, zero-config)

            SSH key at ~/.ssh/id_rsa, host pre-trusted, `ssh devvm`
            Just Works. No password prompts, no host-trust prompts.
            Devvm has: Vault token, kubectl cluster-admin, git repos
            under /home/wizard/code, git-crypt, claude 2.1.126 at
            /usr/local/bin/claude.

            <!-- END openclaw-devvm-section v4 -->
            TOOLS_EOF

            # Insert at top: after first non-blank/non-heading lines.
            # If the file starts with "# TOOLS.md", inject right after.
            awk '
              !inserted && /^# / {
                print
                print ""
                while ((getline line < "/tmp/devvm-section.md") > 0) print line
                close("/tmp/devvm-section.md")
                inserted=1
                next
              }
              { print }
              END {
                if (!inserted) {
                  while ((getline line < "/tmp/devvm-section.md") > 0) print line
                  close("/tmp/devvm-section.md")
                }
              }
            ' "$TOOLS.stripped" > "$TOOLS"
            rm -f "$TOOLS.stripped" /tmp/devvm-section.md
            chown 1000:1000 "$TOOLS"

            # ---- 3. Memory-indexed learned/ scaffold --------------------
            LEARNED=/workspace/memory/projects/openclaw-learned
            mkdir -p "$LEARNED/scripts" "$LEARNED/knowledge" "$LEARNED/credentials"
            chmod 0755 "$LEARNED/credentials"  # pointers only, not secrets
            if [ ! -f "$LEARNED/INDEX.md" ]; then
              cat > "$LEARNED/INDEX.md" <<'INDEX_EOF'
            # openclaw-learned — index

            Things I've figured out (via devvm-claude or self). Check
            here FIRST — `memory_recall "<topic>"` also surfaces these.

            | Task | Type | Path | Source | Added |
            |------|------|------|--------|-------|
            | _example: post to slack_ | script | scripts/slack-post.md | devvm-claude | 2026-05-22 |

            ## Layout

            - `scripts/<task>.md`        — runnable recipes
            - `knowledge/<topic>.md`     — decisions, paths, gotchas
            - `credentials/<name>.md`    — POINTERS to Vault, never values

            ## When you save something new

            1. Drop the file in the right slot above.
            2. Header: WHAT, WHEN learned, HOW (verbatim devvm prompt
               or "self"), SOURCE (Vault path if a credential).
            3. Add a row to this INDEX.
            4. (Optional) `node /app/openclaw.mjs memory index --force`
               to make it immediately searchable; the daily memory-sync
               CronJob re-indexes anyway.

            See the `learn-from-tasks` skill for full protocol.
            INDEX_EOF
            fi
            chown -R 1000:1000 "$LEARNED"

            # Migrate v2 scaffold at /workspace/learned/ into the new
            # memory-indexed location. Only move actual content — if
            # the directory is still empty (no learnings saved yet),
            # remove it so the agent isn't confused by two locations.
            if [ -d /workspace/learned ]; then
              for sub in scripts knowledge credentials; do
                if [ -d "/workspace/learned/$sub" ]; then
                  for f in "/workspace/learned/$sub"/*; do
                    [ -e "$f" ] || continue
                    mv "$f" "$LEARNED/$sub/" 2>/dev/null || true
                  done
                fi
              done
              # Pull INDEX.md rows over too (manual review — leave both
              # for now and let the agent clean up). Then remove v2 dir
              # if empty.
              rmdir /workspace/learned/scripts /workspace/learned/knowledge \
                    /workspace/learned/credentials /workspace/learned \
                    2>/dev/null || true
            fi

            # ---- 5. Skill at cc-skills/learn-from-tasks/ ----------------
            SKILL_DIR=/home/node/.openclaw/cc-skills/learn-from-tasks
            mkdir -p "$SKILL_DIR"
            cat > "$SKILL_DIR/SKILL.md" <<'SKILL_EOF'
            # learn-from-tasks

            **This is universal. EVERY task runs through this flow —
            not just hard ones, not just unfamiliar ones. The save at
            the end is mandatory.**

            > know → ask devvm → (rarely) try yourself → SAVE the recipe

            The goal isn't to answer the current task; the goal is
            to ALSO leave a trail so future-you doesn't need to
            redo the discovery. Every saved recipe compounds. Skip
            the save and you stay at zero.

            ## Triage every new task

            1. **Do I know how?**
               `memory_recall "<topic>"` and scan
               `/workspace/memory/projects/openclaw-learned/INDEX.md`.
               If yes → just do it.

            2. **If not, ASK DEVVM.** This is the default path — most
               tasks land here.

                   ssh devvm 'claude -p --dangerously-skip-permissions \
                     "I am the openclaw agent. I need to do X. Can \
                      you do this? If yes: do it now, then tell me 1) \
                      the exact commands I would run on my own next \
                      time, and 2) what credentials/paths I need (give \
                      Vault paths, NOT values). I will save your \
                      answer."'

               For multi-step work (>2 min), use async:

                   ssh devvm openclaw-task new <id> "<command>"
                   ssh devvm openclaw-task claude <id> "<prompt>"
                   ssh devvm openclaw-task capture / log / status

               When devvm-claude responds, **save what it told you**
               (see "The save" below).

            3. **Only if devvm-claude can't either**, try in-pod. This
               is rare. Be honest with the user about the uncertainty.
               If you find a way, save it just like step 2.

            ## The save — MANDATORY on every non-trivial task

            Don't end the task without it. Even if you self-figured,
            even if it was easy this time — recurrence makes it
            valuable. The exceptions list at the end is tight; bias
            aggressively toward saving.

            All learnings live under
            `/workspace/memory/projects/openclaw-learned/` because
            memory-core indexes that tree.

            1. Pick the slot:
               - **Script / recipe** → `scripts/<task>.md`
                 Fenced code block(s); agent reads + runs from here.
               - **Knowledge** → `knowledge/<topic>.md`
                 Decisions, paths, conventions, gotchas, anti-patterns.
               - **Credential** → `credentials/<name>.md`
                 **POINTER ONLY, never the value.** Vault path + field
                 + fetch command + consumer + rotation expectations.
            2. Header in the file: WHAT, WHEN learned, HOW (verbatim
               devvm prompt, or "self"), SOURCE (Vault path if cred).
            3. Add a row to `openclaw-learned/INDEX.md`.
            4. Test the saved recipe end-to-end. If it doesn't work
               as-saved, the artifact is a lie — fix it before you
               consider the task done.

            ## After every task, ask yourself

            - Could a future-me (or another agent) do this faster by
              reading what I just figured out?
            - Was there any non-obvious URL / Vault path / quirk?
            - Did the first attempt fail and need a tweak?

            If yes to any → save it. The bar is low.

            ## When NOT to save

            Very narrow exceptions:
            - Trivial one-liners (`date`, `whoami`) that take zero
              time to redo.
            - Things that change every run (ephemeral pod names,
              random tokens, timestamps).
            - Values of credentials (use the pointer pattern instead).

            That's it. Everything else, save.
            SKILL_EOF
            chown -R 1000:1000 "$SKILL_DIR"

            echo "learning-loop v4 seeded:"
            echo "  - memory note:  $DIR/devvm-fallback.md"
            echo "  - SOUL.md:      learning-as-identity marker section"
            echo "  - TOOLS.md v4:  flow section INSERTED AT TOP"
            echo "  - openclaw-learned/ at $LEARNED"
            echo "  - skill:        $SKILL_DIR/SKILL.md"
          EOT
          ]
          volume_mount {
            name       = "workspace"
            mount_path = "/workspace"
          }
          volume_mount {
            name       = "openclaw-home"
            mount_path = "/home/node/.openclaw"
          }
          resources {
            requests = { cpu = "10m", memory = "32Mi" }
            limits   = { memory = "64Mi" }
          }
        }

        # Main container: OpenClaw
        container {
          name  = "openclaw"
          image = "ghcr.io/openclaw/openclaw:2026.5.4"
          # Startup sequence:
          #   1. doctor --fix     — repair sessions/state (also resets some config)
          #   2. models set       — pin gpt-5.4-mini (doctor auto-promotes to gpt-5-pro otherwise)
          #   3. mcp set <name>   — register MCP servers via the CLI (the
          #                          ConfigMap-baked mcp.servers block gets
          #                          stripped by doctor --fix, but CLI-written
          #                          entries persist). Values: ha URL from
          #                          $HA_SOFIA_MCP_URL env (Vault-sourced),
          #                          others hard-coded.
          #   4. gateway          — exec into the gateway process
          command = ["sh", "-c", <<-EOC
            # Symlink /home/node/.ssh → persistent .ssh so the ssh client
            # finds id_rsa/config/known_hosts via $HOME/.ssh. HOME is
            # /home/node (image overlay), .ssh files live on the PVC
            # at /home/node/.openclaw/.ssh (set up by init 5).
            ln -sfn /home/node/.openclaw/.ssh /home/node/.ssh
            node openclaw.mjs doctor --fix 2>/dev/null
            node openclaw.mjs models set nim/meta/llama-3.1-70b-instruct 2>/dev/null
            node openclaw.mjs mcp set ha "{\"url\":\"$HA_SOFIA_MCP_URL\",\"transport\":\"streamable-http\"}" 2>/dev/null
            node openclaw.mjs mcp set context7 '{"command":"npx","args":["-y","@upstash/context7-mcp"]}' 2>/dev/null
            node openclaw.mjs mcp set playwright '{"url":"http://localhost:3000/mcp","transport":"streamable-http"}' 2>/dev/null
            # doctor --fix overwrites plugins.allow with its bundled-plugins
            # list. Re-add our third-party plugin to the allow list via
            # `config patch`, then enable it. (Same pattern as mcp set above.)
            echo '{"plugins":{"allow":["memory-core","recruiter-api","telegram","openrouter","brave","openai","codex"]}}' \
              | node openclaw.mjs config patch --stdin 2>/dev/null || true
            node openclaw.mjs plugins enable recruiter-api 2>/dev/null || true
            # Reindex memory-core so the seeded devvm-fallback note (and
            # anything else dropped under /workspace/memory/) is searchable
            # on first boot; daily memory-sync CronJob also keeps it indexed.
            node openclaw.mjs memory index --force 2>/dev/null || true
            exec node openclaw.mjs gateway --allow-unconfigured --bind lan
          EOC
          ]
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
            name = "PATH"
            # Host-tools bundle (installed by init 4: install-host-tools)
            # comes first so ssh/scp/dig/vault/jq/etc. resolve to the
            # extracted Debian binaries + the static-binary downloads.
            # /bin + /sbin are needed because iputils-ping installs ping
            # under /bin (not /usr/bin) on Debian.
            value = "/tools/host-tools/root/usr/bin:/tools/host-tools/root/usr/sbin:/tools/host-tools/root/bin:/tools/host-tools/root/sbin:/tools/host-tools/bin:/tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
          }
          env {
            # Point ld.so at the bundled libs so the host-tools binaries
            # find their shared-lib deps (libgssapi_krb5, libkrb5, etc.).
            # Both base images are bookworm so the libs match the
            # openclaw image's libc/libssl — no ABI conflicts expected.
            name  = "LD_LIBRARY_PATH"
            value = "/tools/host-tools/root/usr/lib/x86_64-linux-gnu:/tools/host-tools/root/lib/x86_64-linux-gnu"
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
          # MCP URL for ha-mcp add-on on ha-sofia (secret-path auth).
          # Consumed in the startup command by `openclaw mcp set ha ...`.
          env {
            name  = "HA_SOFIA_MCP_URL"
            value = data.vault_kv_secret_v2.secrets.data["ha_sofia_mcp_url"]
          }
          # Skill secrets - Uptime Kuma
          env {
            name  = "UPTIME_KUMA_PASSWORD"
            value = local.skill_secrets["uptime_kuma_password"]
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
          # Recruiter Responder API — consumed by the recruiter-api plugin
          # (mounted into /home/node/.openclaw/extensions/recruiter-api/ via
          # the install-recruiter-plugin init container below).
          env {
            name  = "RECRUITER_RESPONDER_URL"
            value = "http://recruiter-responder.recruiter-responder.svc.cluster.local:8080"
          }
          env {
            name = "RECRUITER_RESPONDER_TOKEN"
            value_from {
              secret_key_ref {
                name     = "openclaw-secrets"
                key      = "recruiter_responder_bearer_token"
                optional = true
              }
            }
          }
          # Telegram chat ID for the recruiter-api plugin's announcement loop.
          env {
            name = "VIKTOR_CHAT_ID"
            value_from {
              secret_key_ref {
                name     = "openclaw-secrets"
                key      = "viktor_chat_id"
                optional = true
              }
            }
          }
          # Bot token for the recruiter-api plugin's announceEvent() Telegram
          # send. OpenClaw does not pass api.bot to "kind: tools" plugins, so
          # the plugin's fallback hits the Telegram Bot API directly via this
          # env (OPENLOBSTER_CHANNELS_TELEGRAM_TOKEN). Without it every poll
          # tick throws and events are never consumed -> no notifications.
          # Same token as channels.telegram.botToken in openclaw.json.
          env {
            name = "OPENLOBSTER_CHANNELS_TELEGRAM_TOKEN"
            value_from {
              secret_key_ref {
                name     = "openclaw-secrets"
                key      = "telegram_bot_token"
                optional = true
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

        # Sidecar: openclaw-exporter — Prometheus exporter for Codex/OAuth usage.
        # Reads sessions JSONL files + auth-profiles.json, exposes /metrics on :9099.
        # Stdlib-only Python; no pip install at startup.
        container {
          name    = "openclaw-exporter"
          image   = "docker.io/library/python:3.12-slim"
          command = ["python3", "/scripts/exporter.py"]
          port {
            container_port = 9099
            name           = "metrics"
          }
          env {
            name  = "OPENCLAW_HOME"
            value = "/home/node/.openclaw"
          }
          env {
            name  = "METRICS_PORT"
            value = "9099"
          }
          volume_mount {
            name       = "openclaw-exporter-script"
            mount_path = "/scripts"
            read_only  = true
          }
          volume_mount {
            name       = "openclaw-home"
            mount_path = "/home/node/.openclaw"
            read_only  = true
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 9099
            }
            initial_delay_seconds = 5
            period_seconds        = 30
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "128Mi"
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
        volume {
          name = "openclaw-exporter-script"
          config_map {
            name         = kubernetes_config_map.openclaw_exporter.metadata[0].name
            default_mode = "0555"
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
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
  auth            = "required"
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
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
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
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "none": inbound Forgejo webhook receiver - machine sender (no Authentik SSO cookie); receiver filters on payload action + bot-user
  auth             = "none"
  namespace        = kubernetes_namespace.openclaw.metadata[0].name
  name             = "task-webhook"
  tls_secret_name  = var.tls_secret_name
  host             = "task-webhook"
  port             = 80
  external_monitor = false
}

# --- Shared ServiceAccount: grants pod-exec into the openclaw pod ---
# Used by the task_processor CronJob (below). Previously also used by the
# cluster_healthcheck CronJob, which has been decommissioned — the local
# `scripts/cluster_healthcheck.sh` is now the single authoritative runner.

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
        active_deadline_seconds    = 600
        backoff_limit              = 0
        ttl_seconds_after_finished = 86400
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
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}

# --- CronJob: claude-memory → memory-core sync (daily) ---
# Pulls all (non-sensitive) memories from claude-memory's REST API and
# writes them into memory-core's QMD-backed tree at
# /home/node/.openclaw/memory/projects/claude-memory-sync/. Then runs
# `openclaw memory index --force` to rebuild the search index so the
# OpenClaw agent can `memory_search` over the shared knowledge.
#
# Note: the central claude-memory MCP transport (/mcp/mcp) is broken
# on the deployed image (beads code-z1so) — this REST sync is the
# workaround. Once that's fixed we can also wire claude_memory as a
# native MCP server in the mcp.servers block above.

resource "kubernetes_config_map" "memory_sync_script" {
  metadata {
    name      = "memory-sync-script"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
  }
  data = {
    "memory-sync.py" = file("${path.module}/files/memory-sync.py")
  }
}

resource "kubernetes_cron_job_v1" "memory_sync" {
  metadata {
    name      = "memory-sync"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
    labels = {
      app  = "memory-sync"
      tier = local.tiers.aux
    }
  }
  spec {
    schedule                      = "0 3 * * *"
    concurrency_policy            = "Forbid"
    failed_jobs_history_limit     = 3
    successful_jobs_history_limit = 3

    job_template {
      metadata {
        labels = {
          app = "memory-sync"
        }
      }
      spec {
        active_deadline_seconds    = 600
        backoff_limit              = 0
        ttl_seconds_after_finished = 86400
        template {
          metadata {
            labels = {
              app = "memory-sync"
            }
          }
          spec {
            # Reuses the SA created for the (decommissioned) cluster
            # healthcheck job — already has pods + pods/exec in this ns.
            service_account_name = kubernetes_service_account.healthcheck.metadata[0].name
            restart_policy       = "Never"

            container {
              name  = "memory-sync"
              image = "bitnami/kubectl:latest"
              command = ["bash", "-c", <<-EOF
                set -eu
                POD=$(kubectl get pods -n openclaw -l app=openclaw -o jsonpath='{.items[0].metadata.name}')
                if [ -z "$POD" ]; then
                  echo "ERROR: no openclaw pod"
                  exit 1
                fi
                echo "syncing into pod $POD ..."
                kubectl exec -n openclaw "$POD" -c openclaw -i -- python3 -u - < /scripts/memory-sync.py
                echo "reindexing memory-core ..."
                kubectl exec -n openclaw "$POD" -c openclaw -- sh -c 'cd /app && node openclaw.mjs memory index --force 2>&1 | tail -20'
                echo "memory-sync complete."
              EOF
              ]

              volume_mount {
                name       = "script"
                mount_path = "/scripts"
                read_only  = true
              }

              resources {
                requests = {
                  cpu    = "20m"
                  memory = "64Mi"
                }
                limits = {
                  memory = "64Mi"
                }
              }
            }

            volume {
              name = "script"
              config_map {
                name = kubernetes_config_map.memory_sync_script.metadata[0].name
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

# --- OpenLobster: Multi-user Telegram AI assistant (trial) ---

resource "kubernetes_persistent_volume_claim" "openlobster_data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "openlobster-data-proxmox"
    namespace = kubernetes_namespace.openclaw.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
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
  lifecycle {
    # The autoresizer expands requests.storage up to storage_limit and
    # PVCs can't shrink. Without this, every TF apply tries to revert
    # to the spec value, K8s rejects the shrink, and the PVC ends up
    # in Terminating-but-in-use limbo.
    ignore_changes = [spec[0].resources[0].requests]
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
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["keel.sh/match-tag"],
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — Keel manages tag updates
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
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
  auth            = "required"
}
