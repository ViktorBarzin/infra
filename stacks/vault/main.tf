variable "tls_secret_name" {
  type      = string
  sensitive = true
}

variable "vault_authentik_client_id" { type = string }
variable "vault_authentik_client_secret" {
  type      = string
  sensitive = true
}

variable "nfs_server" {
  type = string
}
resource "kubernetes_namespace" "vault" {
  metadata {
    name = "vault"
    labels = {
      tier = local.tiers.core
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.vault.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "helm_release" "vault" {
  name             = "vault"
  namespace        = kubernetes_namespace.vault.metadata[0].name
  create_namespace = false
  repository       = "https://helm.releases.hashicorp.com"
  chart            = "vault"
  version          = "0.29.1"
  atomic           = false # HA pods start sealed — readiness probes fail until unsealed
  timeout          = 600

  values = [yamlencode({
    global = { enabled = true }

    server = {
      enabled = true

      resources = {
        requests = { memory = "128Mi", cpu = "100m" }
        limits   = { memory = "512Mi" }
      }

      # Allow scheduling on GPU node (node1)
      tolerations = [{
        key      = "nvidia.com/gpu"
        operator = "Exists"
        effect   = "NoSchedule"
      }]

      dataStorage = {
        enabled      = true
        size         = "2Gi"
        storageClass = "nfs-truenas" # NFS — iSCSI CSI driver not available on all nodes
      }

      auditStorage = {
        enabled      = true
        size         = "2Gi"
        storageClass = "nfs-truenas" # NFS fine for append-only audit logs
      }

      standalone = { enabled = false }

      ha = {
        enabled  = true
        replicas = 3

        raft = {
          enabled   = true
          setNodeId = true
          config    = <<-EOT
            ui = true

            listener "tcp" {
              tls_disable     = 1
              address         = "[::]:8200"
              cluster_address = "[::]:8201"
            }

            storage "raft" {
              path = "/vault/data"
              retry_join {
                leader_api_addr = "http://vault-0.vault-internal:8200"
              }
              retry_join {
                leader_api_addr = "http://vault-1.vault-internal:8200"
              }
              retry_join {
                leader_api_addr = "http://vault-2.vault-internal:8200"
              }
            }

            service_registration "kubernetes" {}
          EOT
        }
      }

      # Mount unseal key secret
      extraVolumes = [{
        type = "secret"
        name = "vault-unseal-key"
      }]

      # Auto-unseal sidecar — polls every 10s, unseals if sealed
      extraContainers = [{
        name    = "auto-unseal"
        image   = "hashicorp/vault:1.18.1"
        command = ["/bin/sh", "-c"]
        args = [join("", [
          "while true; do ",
          "sealed=$(VAULT_ADDR=http://127.0.0.1:8200 vault status -format=json 2>/dev/null | grep '\"sealed\"' | grep -o 'true\\|false'); ",
          "if [ \"$sealed\" = \"true\" ]; then ",
          "echo \"$(date): Vault is sealed, unsealing...\"; ",
          "VAULT_ADDR=http://127.0.0.1:8200 vault operator unseal $(cat /vault/unseal-key/unseal-key); ",
          "fi; ",
          "sleep 10; ",
          "done"
        ])]
        volumeMounts = [{
          name      = "userconfig-vault-unseal-key" # Helm chart prefixes extraVolumes with "userconfig-"
          mountPath = "/vault/unseal-key"
          readOnly  = true
        }]
        resources = {
          requests = { cpu = "10m", memory = "128Mi" }
          limits   = { memory = "128Mi" }
        }
      }]
    }

    ui       = { enabled = true }
    injector = { enabled = false }
    csi      = { enabled = false }
  })]
}

# --- OIDC Authentication via Authentik ---

resource "vault_jwt_auth_backend" "oidc" {
  path               = "oidc"
  type               = "oidc"
  oidc_discovery_url = "https://authentik.viktorbarzin.me/application/o/vault/"
  oidc_client_id     = var.vault_authentik_client_id
  oidc_client_secret = var.vault_authentik_client_secret
  default_role       = "default"
  tune {
    listing_visibility = "hidden"
  }
  depends_on = [helm_release.vault]
}

resource "vault_jwt_auth_backend_role" "default" {
  backend        = vault_jwt_auth_backend.oidc.path
  role_name      = "default"
  token_policies = ["default"]
  token_ttl      = 3600
  token_max_ttl  = 86400
  user_claim     = "email"
  groups_claim   = "groups"
  role_type      = "oidc"
  allowed_redirect_uris = [
    "https://vault.viktorbarzin.me/ui/vault/auth/oidc/oidc/callback",
    "http://localhost:8250/oidc/callback",
  ]
  oidc_scopes = ["openid", "email", "profile"]
}

resource "vault_policy" "admin" {
  name   = "vault-admin"
  policy = <<-EOT
    path "*" {
      capabilities = ["create", "read", "update", "delete", "list", "sudo"]
    }
  EOT
}

resource "vault_identity_group" "admins" {
  name     = "authentik-admins"
  type     = "external"
  policies = [vault_policy.admin.name]
}

resource "vault_identity_group_alias" "admins" {
  name           = "authentik Admins"
  mount_accessor = vault_jwt_auth_backend.oidc.accessor
  canonical_id   = vault_identity_group.admins.id
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.vault.metadata[0].name
  name            = "vault"
  tls_secret_name = var.tls_secret_name
  port            = 8200
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Vault"
    "gethomepage.dev/description"  = "HashiCorp Vault - Secrets Management"
    "gethomepage.dev/icon"         = "vault.png"
    "gethomepage.dev/group"        = "Core Platform"
    "gethomepage.dev/pod-selector" = ""
  }
}

# --- Audit Logging ---

resource "vault_audit" "file" {
  type = "file"
  options = {
    file_path = "/vault/audit/vault-audit.log"
  }
  depends_on = [helm_release.vault]
}

# --- Raft Snapshot Backups ---

module "vault_backup_nfs" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "vault-backup"
  namespace  = kubernetes_namespace.vault.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/vault-backup"
  storage    = "5Gi"
}

resource "kubernetes_cron_job_v1" "vault_backup" {
  metadata {
    name      = "vault-raft-backup"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
  spec {
    schedule                      = "0 2 * * *"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    concurrency_policy            = "Forbid"
    job_template {
      metadata {}
      spec {
        template {
          metadata {}
          spec {
            container {
              name    = "backup"
              image   = "hashicorp/vault:1.18.1"
              command = ["/bin/sh", "-c"]
              args = [join("", [
                "export VAULT_ADDR=http://vault-active.vault.svc.cluster.local:8200 && ",
                "export VAULT_TOKEN=$(cat /vault/token/vault-root-token) && ",
                "TIMESTAMP=$(date +%Y%m%d-%H%M%S) && ",
                "vault operator raft snapshot save /backup/vault-raft-$TIMESTAMP.db && ",
                "find /backup -name '*.db' -mtime +30 -delete && ",
                "echo \"Backup done: vault-raft-$TIMESTAMP.db\" && ls -lh /backup/"
              ])]
              volume_mount {
                mount_path = "/backup"
                name       = "backup-storage"
              }
              volume_mount {
                mount_path = "/vault/token"
                name       = "vault-token"
                read_only  = true
              }
            }
            restart_policy = "OnFailure"
            volume {
              name = "backup-storage"
              persistent_volume_claim {
                claim_name = module.vault_backup_nfs.claim_name
              }
            }
            volume {
              name = "vault-token"
              secret {
                secret_name = "vault-root-token"
              }
            }
          }
        }
      }
    }
  }
}

# =============================================================================
# Vault KV Secret Population
# =============================================================================
# Reads secrets from SOPS (-var-file) and writes them to Vault KV v2 at
# secret/<stack-name>. Consuming stacks read from Vault instead of SOPS.
# =============================================================================

# --- Variable Declarations (secrets consumed by other stacks) ---

# Simple string secrets
variable "speedtest_db_password" {
  type      = string
  sensitive = true
}
variable "hackmd_db_password" {
  type      = string
  sensitive = true
}
variable "n8n_postgresql_password" {
  type      = string
  sensitive = true
}
variable "tandoor_database_password" {
  type      = string
  sensitive = true
}
variable "shadowsocks_password" {
  type      = string
  sensitive = true
}
variable "coturn_turn_secret" {
  type      = string
  sensitive = true
}
variable "wealthfolio_password_hash" {
  type      = string
  sensitive = true
}
variable "plotting_book_session_secret" {
  type      = string
  sensitive = true
}
variable "discord_user_token" {
  type      = string
  sensitive = true
}
variable "health_postgresql_password" {
  type      = string
  sensitive = true
}
variable "health_secret_key" {
  type      = string
  sensitive = true
}
variable "onlyoffice_db_password" {
  type      = string
  sensitive = true
}
variable "onlyoffice_jwt_token" {
  type      = string
  sensitive = true
}
variable "netbox_db_password" {
  type      = string
  sensitive = true
}
variable "netbox_superuser_password" {
  type      = string
  sensitive = true
}
variable "clickhouse_password" {
  type      = string
  sensitive = true
}
variable "clickhouse_postgres_password" {
  type      = string
  sensitive = true
}
variable "diun_nfty_token" {
  type      = string
  sensitive = true
}
variable "diun_slack_url" {
  type      = string
  sensitive = true
}
variable "forgejo_authentik_client_id" {
  type      = string
  sensitive = true
}
variable "forgejo_authentik_client_secret" {
  type      = string
  sensitive = true
}
variable "dawarich_database_password" {
  type      = string
  sensitive = true
}
variable "geoapify_api_key" {
  type      = string
  sensitive = true
}
variable "resume_auth_secret" {
  type      = string
  sensitive = true
}
variable "url_shortener_api_key" {
  type      = string
  sensitive = true
}
variable "url_shortener_geolite_license_key" {
  type      = string
  sensitive = true
}
variable "url_shortener_mysql_password" {
  type      = string
  sensitive = true
}
variable "linkwarden_authentik_client_id" {
  type      = string
  sensitive = true
}
variable "linkwarden_authentik_client_secret" {
  type      = string
  sensitive = true
}
variable "linkwarden_postgresql_password" {
  type      = string
  sensitive = true
}
variable "tiny_tuya_api_key" {
  type      = string
  sensitive = true
}
variable "tiny_tuya_api_secret" {
  type      = string
  sensitive = true
}
variable "tiny_tuya_service_secret" {
  type      = string
  sensitive = true
}
variable "tiny_tuya_slack_url" {
  type      = string
  sensitive = true
}
variable "claude_memory_api_key" {
  type      = string
  sensitive = true
}
variable "dbaas_postgresql_root_password" {
  type      = string
  sensitive = true
}
variable "openrouter_api_key" {
  type      = string
  sensitive = true
}
variable "slack_bot_token" {
  type      = string
  sensitive = true
}
variable "woodpecker_agent_secret" {
  type      = string
  sensitive = true
}
variable "woodpecker_db_password" {
  type      = string
  sensitive = true
}
variable "woodpecker_forgejo_client_id" {
  type      = string
  sensitive = true
}
variable "woodpecker_forgejo_client_secret" {
  type      = string
  sensitive = true
}
variable "woodpecker_github_client_id" {
  type      = string
  sensitive = true
}
variable "woodpecker_github_client_secret" {
  type      = string
  sensitive = true
}
variable "webhook_handler_secret" {
  type      = string
  sensitive = true
}
variable "webhook_handler_fb_verify_token" {
  type      = string
  sensitive = true
}
variable "webhook_handler_fb_page_token" {
  type      = string
  sensitive = true
}
variable "webhook_handler_fb_app_secret" {
  type      = string
  sensitive = true
}
variable "webhook_handler_git_user" {
  type      = string
  sensitive = true
}
variable "webhook_handler_git_token" {
  type      = string
  sensitive = true
}
variable "webhook_handler_ssh_key" {
  type      = string
  sensitive = true
}
variable "trading_bot_db_password" {
  type      = string
  sensitive = true
}
variable "trading_bot_alpaca_api_key" {
  type      = string
  sensitive = true
}
variable "trading_bot_alpaca_secret_key" {
  type      = string
  sensitive = true
}
variable "trading_bot_jwt_secret" {
  type      = string
  sensitive = true
}
variable "trading_bot_reddit_client_id" {
  type      = string
  sensitive = true
}
variable "trading_bot_reddit_client_secret" {
  type      = string
  sensitive = true
}
variable "trading_bot_alpha_vantage_api_key" {
  type      = string
  sensitive = true
}
variable "trading_bot_fmp_api_key" {
  type      = string
  sensitive = true
}
variable "openclaw_ssh_key" {
  type      = string
  sensitive = true
}
variable "llama_api_key" {
  type      = string
  sensitive = true
}
variable "brave_api_key" {
  type      = string
  sensitive = true
}
variable "nvidia_api_key" {
  type      = string
  sensitive = true
}
variable "anthropic_api_key" {
  type      = string
  sensitive = true
}
variable "openclaw_telegram_bot_token" {
  type      = string
  sensitive = true
}
variable "forgejo_api_token" {
  type      = string
  sensitive = true
}
variable "affine_postgresql_password" {
  type      = string
  sensitive = true
}
variable "immich_postgresql_password" {
  type      = string
  sensitive = true
}
variable "immich_frame_api_key" {
  type      = string
  sensitive = true
}
variable "nextcloud_db_password" {
  type      = string
  sensitive = true
}
variable "paperless_db_password" {
  type      = string
  sensitive = true
}
variable "realestate_crawler_db_password" {
  type      = string
  sensitive = true
}
variable "aiostreams_database_connection_string" {
  type      = string
  sensitive = true
}

# Platform-specific secrets
variable "dbaas_root_password" {
  type      = string
  sensitive = true
}
variable "dbaas_pgadmin_password" {
  type      = string
  sensitive = true
}
variable "ingress_crowdsec_api_key" {
  type      = string
  sensitive = true
}
variable "auth_fallback_htpasswd" {
  type      = string
  sensitive = true
  default   = ""
}
variable "technitium_db_password" {
  type      = string
  sensitive = true
}
variable "authentik_secret_key" {
  type      = string
  sensitive = true
}
variable "authentik_postgres_password" {
  type      = string
  sensitive = true
}
variable "crowdsec_enroll_key" {
  type      = string
  sensitive = true
}
variable "crowdsec_db_password" {
  type      = string
  sensitive = true
}
variable "crowdsec_dash_api_key" {
  type      = string
  sensitive = true
}
variable "crowdsec_dash_machine_id" {
  type      = string
  sensitive = true
}
variable "crowdsec_dash_machine_password" {
  type      = string
  sensitive = true
}
variable "alertmanager_slack_api_url" {
  type      = string
  sensitive = true
}
variable "cloudflare_api_key" {
  type      = string
  sensitive = true
}
variable "cloudflare_tunnel_token" {
  type      = string
  sensitive = true
}
variable "alertmanager_account_password" {
  type      = string
  sensitive = true
}
variable "monitoring_idrac_password" {
  type      = string
  sensitive = true
}
variable "haos_api_token" {
  type      = string
  sensitive = true
}
variable "pve_password" {
  type      = string
  sensitive = true
}
variable "grafana_db_password" {
  type      = string
  sensitive = true
}
variable "grafana_admin_password" {
  type      = string
  sensitive = true
}
variable "vaultwarden_smtp_password" {
  type      = string
  sensitive = true
}
variable "technitium_username" {
  type      = string
  sensitive = true
}
variable "technitium_password" {
  type      = string
  sensitive = true
}
variable "truenas_api_key" {
  type      = string
  sensitive = true
}
variable "truenas_ssh_private_key" {
  type      = string
  sensitive = true
}
variable "xray_reality_private_key" {
  type      = string
  sensitive = true
}
variable "mailserver_roundcubemail_db_password" {
  type      = string
  sensitive = true
}
variable "headscale_config" {
  type      = string
  sensitive = true
}
variable "headscale_acl" {
  type      = string
  sensitive = true
}
variable "wireguard_wg_0_conf" {
  type      = string
  sensitive = true
}
variable "wireguard_wg_0_key" {
  type      = string
  sensitive = true
}
variable "wireguard_firewall_sh" {
  type      = string
  sensitive = true
}

# Complex type secrets
variable "homepage_credentials" {
  type      = map(any)
  sensitive = true
}
variable "mailserver_accounts" {
  sensitive = true
}
variable "mailserver_aliases" {
  sensitive = true
}
variable "mailserver_opendkim_key" {
  sensitive = true
}
variable "mailserver_sasl_passwd" {
  sensitive = true
}
variable "actualbudget_credentials" {
  type      = map(any)
  sensitive = true
}
variable "freedify_credentials" {
  type      = map(any)
  sensitive = true
}
variable "ollama_api_credentials" {
  type      = map(string)
  sensitive = true
}
variable "owntracks_credentials" {
  type      = map(string)
  sensitive = true
}
variable "realestate_crawler_notification_settings" {
  type      = map(string)
  sensitive = true
}
variable "openclaw_skill_secrets" {
  type      = map(string)
  sensitive = true
}
variable "k8s_users" {
  type      = map(any)
  sensitive = true
  default   = {}
}
variable "xray_reality_clients" {
  type      = list(map(string))
  sensitive = true
}
variable "xray_reality_short_ids" {
  type      = list(string)
  sensitive = true
}

# =============================================================================
# KV Secret Resources — one per consuming stack
# =============================================================================

resource "vault_kv_secret_v2" "speedtest" {
  mount = "secret"
  name  = "speedtest"
  data_json = jsonencode({
    db_password = var.speedtest_db_password
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "hackmd" {
  mount = "secret"
  name  = "hackmd"
  data_json = jsonencode({
    db_password = var.hackmd_db_password
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "n8n" {
  mount = "secret"
  name  = "n8n"
  data_json = jsonencode({
    db_password = var.n8n_postgresql_password
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "tandoor" {
  mount = "secret"
  name  = "tandoor"
  data_json = jsonencode({
    db_password = var.tandoor_database_password
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "shadowsocks" {
  mount = "secret"
  name  = "shadowsocks"
  data_json = jsonencode({
    password = var.shadowsocks_password
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "coturn" {
  mount = "secret"
  name  = "coturn"
  data_json = jsonencode({
    turn_secret = var.coturn_turn_secret
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "wealthfolio" {
  mount = "secret"
  name  = "wealthfolio"
  data_json = jsonencode({
    password_hash = var.wealthfolio_password_hash
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "plotting-book" {
  mount = "secret"
  name  = "plotting-book"
  data_json = jsonencode({
    session_secret = var.plotting_book_session_secret
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "f1-stream" {
  mount = "secret"
  name  = "f1-stream"
  data_json = jsonencode({
    discord_user_token = var.discord_user_token
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "health" {
  mount = "secret"
  name  = "health"
  data_json = jsonencode({
    db_password = var.health_postgresql_password
    secret_key  = var.health_secret_key
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "onlyoffice" {
  mount = "secret"
  name  = "onlyoffice"
  data_json = jsonencode({
    db_password = var.onlyoffice_db_password
    jwt_token   = var.onlyoffice_jwt_token
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "netbox" {
  mount = "secret"
  name  = "netbox"
  data_json = jsonencode({
    db_password        = var.netbox_db_password
    superuser_password = var.netbox_superuser_password
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "rybbit" {
  mount = "secret"
  name  = "rybbit"
  data_json = jsonencode({
    clickhouse_password = var.clickhouse_password
    postgres_password   = var.clickhouse_postgres_password
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "diun" {
  mount = "secret"
  name  = "diun"
  data_json = jsonencode({
    nfty_token = var.diun_nfty_token
    slack_url  = var.diun_slack_url
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "forgejo" {
  mount = "secret"
  name  = "forgejo"
  data_json = jsonencode({
    authentik_client_id     = var.forgejo_authentik_client_id
    authentik_client_secret = var.forgejo_authentik_client_secret
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "dawarich" {
  mount = "secret"
  name  = "dawarich"
  data_json = jsonencode({
    db_password    = var.dawarich_database_password
    geoapify_api_key = var.geoapify_api_key
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "resume" {
  mount = "secret"
  name  = "resume"
  data_json = jsonencode({
    auth_secret        = var.resume_auth_secret
    mailserver_accounts = jsonencode(var.mailserver_accounts)
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "url" {
  mount = "secret"
  name  = "url"
  data_json = jsonencode({
    api_key            = var.url_shortener_api_key
    geolite_license_key = var.url_shortener_geolite_license_key
    db_password        = var.url_shortener_mysql_password
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "linkwarden" {
  mount = "secret"
  name  = "linkwarden"
  data_json = jsonencode({
    authentik_client_id     = var.linkwarden_authentik_client_id
    authentik_client_secret = var.linkwarden_authentik_client_secret
    db_password             = var.linkwarden_postgresql_password
    homepage_credentials    = jsonencode(var.homepage_credentials)
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "tuya-bridge" {
  mount = "secret"
  name  = "tuya-bridge"
  data_json = jsonencode({
    api_key        = var.tiny_tuya_api_key
    api_secret     = var.tiny_tuya_api_secret
    service_secret = var.tiny_tuya_service_secret
    slack_url      = var.tiny_tuya_slack_url
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "claude-memory" {
  mount = "secret"
  name  = "claude-memory"
  data_json = jsonencode({
    api_key            = var.claude_memory_api_key
    dbaas_root_password = var.dbaas_postgresql_root_password
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "ytdlp" {
  mount = "secret"
  name  = "ytdlp"
  data_json = jsonencode({
    openrouter_api_key = var.openrouter_api_key
    slack_bot_token    = var.slack_bot_token
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "woodpecker" {
  mount = "secret"
  name  = "woodpecker"
  data_json = jsonencode({
    dbaas_root_password    = var.dbaas_postgresql_root_password
    agent_secret           = var.woodpecker_agent_secret
    db_password            = var.woodpecker_db_password
    forgejo_client_id      = var.woodpecker_forgejo_client_id
    forgejo_client_secret  = var.woodpecker_forgejo_client_secret
    github_client_id       = var.woodpecker_github_client_id
    github_client_secret   = var.woodpecker_github_client_secret
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "webhook_handler" {
  mount = "secret"
  name  = "webhook-handler"
  data_json = jsonencode({
    secret          = var.webhook_handler_secret
    fb_verify_token = var.webhook_handler_fb_verify_token
    fb_page_token   = var.webhook_handler_fb_page_token
    fb_app_secret   = var.webhook_handler_fb_app_secret
    git_user        = var.webhook_handler_git_user
    git_token       = var.webhook_handler_git_token
    ssh_key         = var.webhook_handler_ssh_key
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "trading-bot" {
  mount = "secret"
  name  = "trading-bot"
  data_json = jsonencode({
    dbaas_root_password    = var.dbaas_postgresql_root_password
    db_password            = var.trading_bot_db_password
    alpaca_api_key         = var.trading_bot_alpaca_api_key
    alpaca_secret_key      = var.trading_bot_alpaca_secret_key
    jwt_secret             = var.trading_bot_jwt_secret
    reddit_client_id       = var.trading_bot_reddit_client_id
    reddit_client_secret   = var.trading_bot_reddit_client_secret
    alpha_vantage_api_key  = var.trading_bot_alpha_vantage_api_key
    fmp_api_key            = var.trading_bot_fmp_api_key
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "openclaw" {
  mount = "secret"
  name  = "openclaw"
  data_json = jsonencode({
    ssh_key              = var.openclaw_ssh_key
    skill_secrets        = jsonencode(var.openclaw_skill_secrets)
    llama_api_key        = var.llama_api_key
    brave_api_key        = var.brave_api_key
    openrouter_api_key   = var.openrouter_api_key
    nvidia_api_key       = var.nvidia_api_key
    anthropic_api_key    = var.anthropic_api_key
    telegram_bot_token   = var.openclaw_telegram_bot_token
    forgejo_api_token    = var.forgejo_api_token
    claude_memory_api_key = var.claude_memory_api_key
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "affine" {
  mount = "secret"
  name  = "affine"
  data_json = jsonencode({
    db_password         = var.affine_postgresql_password
    mailserver_accounts = jsonencode(var.mailserver_accounts)
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "grampsweb" {
  mount = "secret"
  name  = "grampsweb"
  data_json = jsonencode({
    mailserver_accounts = jsonencode(var.mailserver_accounts)
  })
  depends_on = [helm_release.vault]
}

# --- Homepage-only stacks ---

resource "vault_kv_secret_v2" "audiobookshelf" {
  mount = "secret"
  name  = "audiobookshelf"
  data_json = jsonencode({
    homepage_credentials = jsonencode(var.homepage_credentials)
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "calibre" {
  mount = "secret"
  name  = "calibre"
  data_json = jsonencode({
    homepage_credentials = jsonencode(var.homepage_credentials)
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "changedetection" {
  mount = "secret"
  name  = "changedetection"
  data_json = jsonencode({
    homepage_credentials = jsonencode(var.homepage_credentials)
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "freshrss" {
  mount = "secret"
  name  = "freshrss"
  data_json = jsonencode({
    homepage_credentials = jsonencode(var.homepage_credentials)
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "navidrome" {
  mount = "secret"
  name  = "navidrome"
  data_json = jsonencode({
    homepage_credentials = jsonencode(var.homepage_credentials)
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "servarr" {
  mount = "secret"
  name  = "servarr"
  data_json = jsonencode({
    homepage_credentials              = jsonencode(var.homepage_credentials)
    aiostreams_database_connection_string = var.aiostreams_database_connection_string
  })
  depends_on = [helm_release.vault]
}

# --- Complex stacks (map secrets) ---

resource "vault_kv_secret_v2" "actualbudget" {
  mount = "secret"
  name  = "actualbudget"
  data_json = jsonencode({
    credentials = jsonencode(var.actualbudget_credentials)
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "freedify" {
  mount = "secret"
  name  = "freedify"
  data_json = jsonencode({
    credentials = jsonencode(var.freedify_credentials)
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "ollama" {
  mount = "secret"
  name  = "ollama"
  data_json = jsonencode({
    api_credentials = jsonencode(var.ollama_api_credentials)
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "owntracks" {
  mount = "secret"
  name  = "owntracks"
  data_json = jsonencode({
    credentials = jsonencode(var.owntracks_credentials)
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "real-estate-crawler" {
  mount = "secret"
  name  = "real-estate-crawler"
  data_json = jsonencode({
    db_password            = var.realestate_crawler_db_password
    notification_settings  = jsonencode(var.realestate_crawler_notification_settings)
  })
  depends_on = [helm_release.vault]
}

# --- Stacks with homepage_credentials + other secrets ---

resource "vault_kv_secret_v2" "immich" {
  mount = "secret"
  name  = "immich"
  data_json = jsonencode({
    db_password          = var.immich_postgresql_password
    frame_api_key        = var.immich_frame_api_key
    homepage_credentials = jsonencode(var.homepage_credentials)
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "nextcloud" {
  mount = "secret"
  name  = "nextcloud"
  data_json = jsonencode({
    db_password          = var.nextcloud_db_password
    homepage_credentials = jsonencode(var.homepage_credentials)
  })
  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "paperless-ngx" {
  mount = "secret"
  name  = "paperless-ngx"
  data_json = jsonencode({
    db_password          = var.paperless_db_password
    homepage_credentials = jsonencode(var.homepage_credentials)
  })
  depends_on = [helm_release.vault]
}

# --- Platform stack (largest — all core/cluster secrets) ---

resource "vault_kv_secret_v2" "platform" {
  mount = "secret"
  name  = "platform"
  data_json = jsonencode({
    dbaas_root_password              = var.dbaas_root_password
    dbaas_postgresql_root_password   = var.dbaas_postgresql_root_password
    dbaas_pgadmin_password           = var.dbaas_pgadmin_password
    ingress_crowdsec_api_key         = var.ingress_crowdsec_api_key
    auth_fallback_htpasswd           = var.auth_fallback_htpasswd
    technitium_db_password           = var.technitium_db_password
    homepage_credentials             = jsonencode(var.homepage_credentials)
    headscale_config                 = var.headscale_config
    headscale_acl                    = var.headscale_acl
    authentik_secret_key             = var.authentik_secret_key
    authentik_postgres_password      = var.authentik_postgres_password
    k8s_users                        = jsonencode(var.k8s_users)
    crowdsec_enroll_key              = var.crowdsec_enroll_key
    crowdsec_db_password             = var.crowdsec_db_password
    crowdsec_dash_api_key            = var.crowdsec_dash_api_key
    crowdsec_dash_machine_id         = var.crowdsec_dash_machine_id
    crowdsec_dash_machine_password   = var.crowdsec_dash_machine_password
    alertmanager_slack_api_url       = var.alertmanager_slack_api_url
    cloudflare_api_key               = var.cloudflare_api_key
    cloudflare_tunnel_token          = var.cloudflare_tunnel_token
    alertmanager_account_password    = var.alertmanager_account_password
    monitoring_idrac_password        = var.monitoring_idrac_password
    tiny_tuya_service_secret         = var.tiny_tuya_service_secret
    haos_api_token                   = var.haos_api_token
    pve_password                     = var.pve_password
    grafana_db_password              = var.grafana_db_password
    grafana_admin_password           = var.grafana_admin_password
    vaultwarden_smtp_password        = var.vaultwarden_smtp_password
    wireguard_wg_0_conf              = var.wireguard_wg_0_conf
    wireguard_wg_0_key               = var.wireguard_wg_0_key
    wireguard_firewall_sh            = var.wireguard_firewall_sh
    xray_reality_clients             = jsonencode(var.xray_reality_clients)
    xray_reality_private_key         = var.xray_reality_private_key
    xray_reality_short_ids           = jsonencode(var.xray_reality_short_ids)
    mailserver_accounts              = jsonencode(var.mailserver_accounts)
    mailserver_aliases               = jsonencode(var.mailserver_aliases)
    mailserver_opendkim_key          = jsonencode(var.mailserver_opendkim_key)
    mailserver_sasl_passwd           = jsonencode(var.mailserver_sasl_passwd)
    mailserver_roundcubemail_db_password = var.mailserver_roundcubemail_db_password
    webhook_handler_git_user         = var.webhook_handler_git_user
    webhook_handler_git_token        = var.webhook_handler_git_token
    technitium_username              = var.technitium_username
    technitium_password              = var.technitium_password
    truenas_api_key                  = var.truenas_api_key
    truenas_ssh_private_key          = var.truenas_ssh_private_key
  })
  depends_on = [helm_release.vault]
}

