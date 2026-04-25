variable "tls_secret_name" {
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
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
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
        requests = { memory = "384Mi", cpu = "100m" }
        limits   = { memory = "384Mi" }
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
        storageClass = "proxmox-lvm-encrypted" # Migrated 2026-04-25 from nfs-proxmox; raft fsync is NFS-hostile (post-mortems/2026-04-22-vault-raft-leader-deadlock.md)
      }

      auditStorage = {
        enabled      = true
        size         = "2Gi"
        storageClass = "proxmox-lvm-encrypted" # Migrated 2026-04-25 from nfs-proxmox
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

      # fsGroupChangePolicy=OnRootMismatch skips recursive chown on restart.
      # Without this, kubelet walks every file over NFS each restart; during
      # 2026-04-22 outage this looped for 10m+ and blocked quorum recovery.
      # The other four fields restore the chart defaults — providing pod{}
      # replaces them, and missing fsGroup left vault unable to write to
      # the freshly-formatted ext4 PVC during the 2026-04-25 migration.
      statefulSet = {
        securityContext = {
          pod = {
            fsGroupChangePolicy = "OnRootMismatch"
            fsGroup             = 1000
            runAsGroup          = 1000
            runAsUser           = 100
            runAsNonRoot        = true
          }
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

# --- Self-read: Vault's own OIDC credentials from KV ---

data "vault_kv_secret_v2" "vault" {
  mount      = "secret"
  name       = "vault"
  depends_on = [helm_release.vault]
}

# --- OIDC Authentication via Authentik ---

resource "vault_jwt_auth_backend" "oidc" {
  path               = "oidc"
  type               = "oidc"
  oidc_discovery_url = "https://authentik.viktorbarzin.me/application/o/vault/"
  oidc_client_id     = data.vault_kv_secret_v2.vault.data["authentik_client_id"]
  oidc_client_secret = data.vault_kv_secret_v2.vault.data["authentik_client_secret"]
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
  token_ttl      = 604800
  token_max_ttl  = 604800
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

resource "vault_policy" "sops_admin" {
  name   = "sops-admin"
  policy = <<-EOT
    path "transit/encrypt/sops-state-*" { capabilities = ["update"] }
    path "transit/decrypt/sops-state-*" { capabilities = ["update"] }
    path "transit/keys/sops-state-*"    { capabilities = ["create", "read", "update"] }
  EOT
}

resource "vault_identity_group" "admins" {
  name     = "authentik-admins"
  type     = "external"
  policies = [vault_policy.admin.name, vault_policy.sops_admin.name]
}

resource "vault_identity_group_alias" "admins" {
  name           = "authentik Admins"
  mount_accessor = vault_jwt_auth_backend.oidc.accessor
  canonical_id   = vault_identity_group.admins.id
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.vault.metadata[0].name
  name            = "vault"
  service_name    = "vault-active"
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

module "vault_backup_nfs_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "vault-backup-host"
  namespace  = kubernetes_namespace.vault.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/vault-backup"
  storage    = "5Gi"
}

resource "kubernetes_cron_job_v1" "vault_backup" {
  metadata {
    name      = "vault-raft-backup"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
  spec {
    schedule                      = "0 2 * * 0"
    successful_jobs_history_limit = 3
    failed_jobs_history_limit     = 3
    concurrency_policy            = "Forbid"
    job_template {
      metadata {}
      spec {
        backoff_limit = 6
        template {
          metadata {}
          spec {
            container {
              name    = "backup"
              image   = "hashicorp/vault:1.18.1"
              command = ["/bin/sh", "-c"]
              args = [join("", [
                "set -eu; ",
                "_t0=$(date +%s); ",
                "_rb0=$(awk '/^read_bytes/{print $2}' /proc/$$/io 2>/dev/null || echo 0); ",
                "_wb0=$(awk '/^write_bytes/{print $2}' /proc/$$/io 2>/dev/null || echo 0); ",
                "export VAULT_ADDR=http://vault-active.vault.svc.cluster.local:8200 && ",
                "export VAULT_TOKEN=$(cat /vault/token/vault-root-token) && ",
                "TIMESTAMP=$(date +%Y%m%d-%H%M%S) && ",
                "vault operator raft snapshot save /backup/vault-raft-$TIMESTAMP.db && ",
                "find /backup -name '*.db' -mtime +30 -delete && ",
                "echo \"Backup done: vault-raft-$TIMESTAMP.db\" && ls -lh /backup/ && ",
                "_dur=$(( $(date +%s) - _t0 )); ",
                "_rb1=$(awk '/^read_bytes/{print $2}' /proc/$$/io 2>/dev/null || echo 0); ",
                "_wb1=$(awk '/^write_bytes/{print $2}' /proc/$$/io 2>/dev/null || echo 0); ",
                "echo '=== Backup IO Stats ==='; ",
                "echo \"duration: $${_dur}s\"; ",
                "echo \"read:    $(( (_rb1 - _rb0) / 1048576 )) MiB\"; ",
                "echo \"written: $(( (_wb1 - _wb0) / 1048576 )) MiB\"; ",
                "echo \"output:  $(ls -lh /backup/vault-raft-$TIMESTAMP.db | awk '{print $5}')\"; ",
                "_out_bytes=$(stat -c%s /backup/vault-raft-$TIMESTAMP.db); ",
                "wget -qO- --post-data \"backup_duration_seconds $${_dur}\nbackup_read_bytes $((_rb1 - _rb0))\nbackup_written_bytes $((_wb1 - _wb0))\nbackup_output_bytes $${_out_bytes}\nbackup_last_success_timestamp $(date +%s)\n\" ",
                "\"http://prometheus-prometheus-pushgateway.monitoring:9091/metrics/job/vault-raft-backup\" || true"
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
                claim_name = module.vault_backup_nfs_host.claim_name
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
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].job_template[0].spec[0].template[0].spec[0].dns_config]
  }
}

# =============================================================================
# Kubernetes Auth Method
# =============================================================================
# Used by ESO, Woodpecker CI, and OpenClaw to authenticate to Vault.

resource "vault_auth_backend" "kubernetes" {
  type       = "kubernetes"
  depends_on = [helm_release.vault]
}

resource "vault_kubernetes_auth_backend_config" "k8s" {
  backend         = vault_auth_backend.kubernetes.path
  kubernetes_host = "https://kubernetes.default.svc"
}

# --- CI Policy & Role (Woodpecker) ---

resource "vault_policy" "ci" {
  name   = "ci"
  policy = <<-EOT
    path "secret/data/*" {
      capabilities = ["read", "list"]
    }
    path "secret/metadata/*" {
      capabilities = ["list"]
    }
    # Allow CI to write k8s_users during automated user provisioning
    path "secret/data/platform" {
      capabilities = ["create", "read", "update"]
    }
    # Allow CI to get dynamic K8s deploy tokens for user namespaces
    path "kubernetes/creds/*-deployer" {
      capabilities = ["read"]
    }
    # SOPS state encrypt/decrypt (per-stack Transit keys)
    path "transit/encrypt/sops-state-*" {
      capabilities = ["update"]
    }
    path "transit/decrypt/sops-state-*" {
      capabilities = ["update"]
    }
    path "transit/keys/sops-state-*" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_kubernetes_auth_backend_role" "ci" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "ci"
  bound_service_account_names      = ["default"]
  bound_service_account_namespaces = ["woodpecker"]
  # terraform_state policy grants `database/static-creds/pg-terraform-state`
  # read — scripts/tg needs this to fetch the Tier-1 PG backend password.
  # Without it, CI's per-stack `tg apply` dies with
  # `ERROR: Cannot read PG credentials from Vault` and the default.yml
  # apply-loop swallows the exit code (set +e) — fixed in bd code-e1x.
  token_policies = [vault_policy.ci.name, vault_policy.terraform_state.name]
  token_ttl      = 604800 # 7d
  token_period   = 604800 # periodic: auto-renews indefinitely
}

# --- ESO Policy & Role ---

resource "vault_policy" "eso_reader" {
  name   = "eso-reader"
  policy = <<-EOT
    # KV secrets
    path "secret/data/*" {
      capabilities = ["read", "list"]
    }
    # Deny access to vault's administrative secrets
    path "secret/data/vault" {
      capabilities = ["deny"]
    }
    path "database/static-creds/*" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_kubernetes_auth_backend_role" "eso" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "eso"
  bound_service_account_names      = ["external-secrets"]
  bound_service_account_namespaces = ["external-secrets"]
  token_policies                   = [vault_policy.eso_reader.name]
  token_ttl                        = 864000 # 10d (staggered from ci/openclaw)
  token_period                     = 864000 # periodic: auto-renews indefinitely
}

# --- Woodpecker Secret Sync Policy & Role ---

resource "vault_policy" "woodpecker_sync" {
  name   = "woodpecker-sync"
  policy = <<-EOT
    path "secret/data/ci/*" {
      capabilities = ["read", "list"]
    }
  EOT
}

resource "vault_kubernetes_auth_backend_role" "woodpecker_sync" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "woodpecker-sync"
  bound_service_account_names      = ["default"]
  bound_service_account_namespaces = ["woodpecker"]
  token_policies                   = [vault_policy.woodpecker_sync.name]
  token_ttl                        = 691200 # 8d (staggered from others)
  token_period                     = 691200 # periodic: auto-renews indefinitely
}

# --- OpenClaw Policy & Role ---

resource "vault_policy" "openclaw_k8s" {
  name   = "openclaw-k8s"
  policy = <<-EOT
    path "kubernetes/creds/openclaw" {
      capabilities = ["read"]
    }
    path "secret/data/*" {
      capabilities = ["read", "list"]
    }
  EOT
}

resource "vault_kubernetes_auth_backend_role" "openclaw" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "openclaw"
  bound_service_account_names      = ["openclaw"]
  bound_service_account_namespaces = ["openclaw"]
  token_policies                   = [vault_policy.openclaw_k8s.name]
  token_ttl                        = 777600 # 9d (staggered from others)
  token_period                     = 777600 # periodic: auto-renews indefinitely
}

# --- Terraform State Policy & Role (Claude Agent) ---

resource "vault_policy" "terraform_state" {
  name   = "terraform-state"
  policy = <<-EOT
    path "database/static-creds/pg-terraform-state" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_kubernetes_auth_backend_role" "terraform_state" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "terraform-state"
  bound_service_account_names      = ["default"]
  bound_service_account_namespaces = ["claude-agent"]
  token_policies                   = [vault_policy.terraform_state.name]
  token_ttl                        = 518400 # 6d (staggered from others: ci=7d, eso=10d, woodpecker=8d, openclaw=9d)
  token_period                     = 518400 # periodic: auto-renews indefinitely
}

# =============================================================================
# Database Secrets Engine — Static Password Rotation
# =============================================================================
# Rotates app-level DB passwords automatically. Root/operator passwords excluded.

resource "vault_mount" "database" {
  path       = "database"
  type       = "database"
  depends_on = [helm_release.vault]
}

# MySQL connection — app user rotation only
resource "vault_database_secret_backend_connection" "mysql" {
  backend = vault_mount.database.path
  name    = "mysql"
  allowed_roles = [
    "mysql-speedtest", "mysql-wrongmove", "mysql-codimd",
    "mysql-nextcloud", "mysql-shlink", "mysql-grafana",
    "mysql-technitium", "mysql-phpipam"
  ]

  mysql {
    connection_url = "{{username}}:{{password}}@tcp(mysql.dbaas.svc.cluster.local:3306)/"
    username       = "root"
    password       = data.vault_kv_secret_v2.vault.data["dbaas_root_password"]
  }
  depends_on = [vault_mount.database]
}

# PostgreSQL connection — CNPG superuser
resource "vault_database_secret_backend_connection" "postgresql" {
  backend = vault_mount.database.path
  name    = "postgresql"
  allowed_roles = [
    # "pg-trading",  # Commented out 2026-04-06 - trading-bot disabled
    "pg-health", "pg-linkwarden",
    "pg-affine", "pg-woodpecker", "pg-claude-memory",
    "pg-terraform-state", "pg-payslip-ingest", "pg-job-hunter",
    "pg-wealthfolio-sync"
  ]

  postgresql {
    connection_url = "postgresql://{{username}}:{{password}}@postgresql.dbaas.svc.cluster.local:5432/postgres?sslmode=disable"
    username       = "postgres"
    password       = data.vault_kv_secret_v2.vault.data["dbaas_postgresql_root_password"]
  }
  depends_on = [vault_mount.database]
}

# --- MySQL Static Roles ---

resource "vault_database_secret_backend_static_role" "mysql_speedtest" {
  backend         = vault_mount.database.path
  db_name         = vault_database_secret_backend_connection.mysql.name
  name            = "mysql-speedtest"
  username        = "speedtest"
  rotation_period = 604800
}

resource "vault_database_secret_backend_static_role" "mysql_wrongmove" {
  backend         = vault_mount.database.path
  db_name         = vault_database_secret_backend_connection.mysql.name
  name            = "mysql-wrongmove"
  username        = "wrongmove"
  rotation_period = 604800
}

resource "vault_database_secret_backend_static_role" "mysql_codimd" {
  backend         = vault_mount.database.path
  db_name         = vault_database_secret_backend_connection.mysql.name
  name            = "mysql-codimd"
  username        = "codimd"
  rotation_period = 604800
}

resource "vault_database_secret_backend_static_role" "mysql_nextcloud" {
  backend         = vault_mount.database.path
  db_name         = vault_database_secret_backend_connection.mysql.name
  name            = "mysql-nextcloud"
  username        = "nextcloud"
  rotation_period = 604800
}

resource "vault_database_secret_backend_static_role" "mysql_shlink" {
  backend         = vault_mount.database.path
  db_name         = vault_database_secret_backend_connection.mysql.name
  name            = "mysql-shlink"
  username        = "shlink"
  rotation_period = 604800
}

resource "vault_database_secret_backend_static_role" "mysql_grafana" {
  backend         = vault_mount.database.path
  db_name         = vault_database_secret_backend_connection.mysql.name
  name            = "mysql-grafana"
  username        = "grafana"
  rotation_period = 604800
}

resource "vault_database_secret_backend_static_role" "mysql_technitium" {
  backend         = vault_mount.database.path
  db_name         = vault_database_secret_backend_connection.mysql.name
  name            = "mysql-technitium"
  username        = "technitium"
  rotation_period = 604800
}

resource "vault_database_secret_backend_static_role" "mysql_phpipam" {
  backend         = vault_mount.database.path
  db_name         = vault_database_secret_backend_connection.mysql.name
  name            = "mysql-phpipam"
  username        = "phpipam"
  rotation_period = 604800
}

# --- PostgreSQL Static Roles ---

/*
# Commented out 2026-04-06 - trading-bot disabled
resource "vault_database_secret_backend_static_role" "pg_trading" {
  backend         = vault_mount.database.path
  db_name         = vault_database_secret_backend_connection.postgresql.name
  name            = "pg-trading"
  username        = "trading"
  rotation_period = 604800
}
*/

resource "vault_database_secret_backend_static_role" "pg_health" {
  backend         = vault_mount.database.path
  db_name         = vault_database_secret_backend_connection.postgresql.name
  name            = "pg-health"
  username        = "health"
  rotation_period = 604800
}

resource "vault_database_secret_backend_static_role" "pg_linkwarden" {
  backend         = vault_mount.database.path
  db_name         = vault_database_secret_backend_connection.postgresql.name
  name            = "pg-linkwarden"
  username        = "linkwarden"
  rotation_period = 604800
}

resource "vault_database_secret_backend_static_role" "pg_affine" {
  backend         = vault_mount.database.path
  db_name         = vault_database_secret_backend_connection.postgresql.name
  name            = "pg-affine"
  username        = "affine"
  rotation_period = 604800
}

resource "vault_database_secret_backend_static_role" "pg_woodpecker" {
  backend         = vault_mount.database.path
  db_name         = vault_database_secret_backend_connection.postgresql.name
  name            = "pg-woodpecker"
  username        = "woodpecker"
  rotation_period = 604800
}

resource "vault_database_secret_backend_static_role" "pg_claude_memory" {
  backend         = vault_mount.database.path
  db_name         = vault_database_secret_backend_connection.postgresql.name
  name            = "pg-claude-memory"
  username        = "claude_memory"
  rotation_period = 604800
}

resource "vault_database_secret_backend_static_role" "pg_terraform_state" {
  backend         = vault_mount.database.path
  db_name         = vault_database_secret_backend_connection.postgresql.name
  name            = "pg-terraform-state"
  username        = "terraform_state"
  rotation_period = 604800
}

resource "vault_database_secret_backend_static_role" "pg_payslip_ingest" {
  backend         = vault_mount.database.path
  db_name         = vault_database_secret_backend_connection.postgresql.name
  name            = "pg-payslip-ingest"
  username        = "payslip_ingest"
  rotation_period = 604800
}

resource "vault_database_secret_backend_static_role" "pg_job_hunter" {
  backend         = vault_mount.database.path
  db_name         = vault_database_secret_backend_connection.postgresql.name
  name            = "pg-job-hunter"
  username        = "job_hunter"
  rotation_period = 604800
}

resource "vault_database_secret_backend_static_role" "pg_wealthfolio_sync" {
  backend         = vault_mount.database.path
  db_name         = vault_database_secret_backend_connection.postgresql.name
  name            = "pg-wealthfolio-sync"
  username        = "wealthfolio_sync"
  rotation_period = 604800
}

# =============================================================================
# Kubernetes Secrets Engine — Dynamic K8s Credentials
# =============================================================================

resource "vault_kubernetes_secret_backend" "k8s" {
  path                 = "kubernetes"
  kubernetes_host      = "https://kubernetes.default.svc"
  disable_local_ca_jwt = false
  depends_on           = [helm_release.vault]
}

# RBAC for Vault to manage K8s tokens/SAs
resource "kubernetes_cluster_role" "vault_k8s_engine" {
  metadata { name = "vault-k8s-engine" }
  rule {
    api_groups = [""]
    resources  = ["serviceaccounts/token"]
    verbs      = ["create"]
  }
  rule {
    api_groups = [""]
    resources  = ["serviceaccounts"]
    verbs      = ["get", "create", "update", "delete"]
  }
  rule {
    api_groups = ["rbac.authorization.k8s.io"]
    resources  = ["rolebindings", "clusterrolebindings"]
    verbs      = ["create", "update", "delete"]
  }
  rule {
    api_groups = ["rbac.authorization.k8s.io"]
    resources  = ["roles", "clusterroles"]
    verbs      = ["bind", "escalate"]
  }
}

resource "kubernetes_cluster_role_binding" "vault_k8s_engine" {
  metadata { name = "vault-k8s-engine" }
  subject {
    kind      = "ServiceAccount"
    name      = "vault"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.vault_k8s_engine.metadata[0].name
  }
}

# --- K8s Dashboard — short-lived admin tokens ---

resource "vault_kubernetes_secret_backend_role" "dashboard_admin" {
  backend                       = vault_kubernetes_secret_backend.k8s.path
  name                          = "dashboard-admin"
  allowed_kubernetes_namespaces = ["kubernetes-dashboard"]
  token_default_ttl             = 3600
  token_max_ttl                 = 86400
  service_account_name          = "kubernetes-dashboard"
}

# --- CI Deployer — scoped pipeline credentials ---

resource "kubernetes_cluster_role" "ci_deployer" {
  metadata { name = "ci-deployer" }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "list", "patch"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list"]
  }
}

resource "vault_kubernetes_secret_backend_role" "ci_deployer" {
  backend                       = vault_kubernetes_secret_backend.k8s.path
  name                          = "ci-deployer"
  allowed_kubernetes_namespaces = ["*"]
  token_default_ttl             = 1800
  token_max_ttl                 = 3600
  kubernetes_role_type          = "ClusterRole"
  kubernetes_role_name          = kubernetes_cluster_role.ci_deployer.metadata[0].name
}

# --- OpenClaw — short-lived tokens for existing SA ---

resource "vault_kubernetes_secret_backend_role" "openclaw" {
  backend                       = vault_kubernetes_secret_backend.k8s.path
  name                          = "openclaw"
  allowed_kubernetes_namespaces = ["*"]
  token_default_ttl             = 3600
  token_max_ttl                 = 86400
  service_account_name          = "openclaw"
}

# --- Local Admin — dynamic kubeconfig tokens ---

resource "vault_kubernetes_secret_backend_role" "local_admin" {
  backend                       = vault_kubernetes_secret_backend.k8s.path
  name                          = "local-admin"
  allowed_kubernetes_namespaces = ["*"]
  token_default_ttl             = 3600
  token_max_ttl                 = 86400
  kubernetes_role_type          = "ClusterRole"
  kubernetes_role_name          = "cluster-admin"
}

# =============================================================================
# Multi-User Namespace Onboarding
# =============================================================================
# All resources below are auto-generated from the k8s_users map in Vault KV.
# Adding a new user requires only a JSON entry in secret/platform → k8s_users.

data "vault_kv_secret_v2" "platform" {
  mount      = "secret"
  name       = "platform"
  depends_on = [helm_release.vault]
}

locals {
  k8s_users = jsondecode(data.vault_kv_secret_v2.platform.data["k8s_users"])

  # Flatten user -> namespace pairs for namespace-owners
  namespace_owner_namespaces = flatten([
    for name, user in local.k8s_users : [
      for ns in user.namespaces : {
        user_key  = name
        namespace = ns
        email     = user.email
      }
    ] if user.role == "namespace-owner"
  ])

  # Unique namespaces across all namespace-owners
  user_namespaces = toset(flatten([
    for name, user in local.k8s_users : user.namespaces
    if user.role == "namespace-owner"
  ]))
}

resource "kubernetes_namespace" "user_namespace" {
  for_each = nonsensitive(local.user_namespaces)

  metadata {
    name = each.value
    labels = {
      tier                               = "4-aux"
      "resource-governance/custom-quota" = "true"
      "managed-by"                       = "vault-user-onboarding"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "vault_policy" "namespace_owner" {
  for_each = nonsensitive({
    for name, user in local.k8s_users : name => user
    if user.role == "namespace-owner"
  })

  name   = "namespace-owner-${each.key}"
  policy = <<-EOT
    # Read/write own secrets
    path "secret/data/${each.key}" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }
    path "secret/data/${each.key}/*" {
      capabilities = ["create", "read", "update", "delete", "list"]
    }
    path "secret/metadata/${each.key}" {
      capabilities = ["list", "read", "delete"]
    }
    path "secret/metadata/${each.key}/*" {
      capabilities = ["list", "read", "delete"]
    }
    %{for ns in each.value.namespaces}
    # Dynamic K8s credentials for ${ns} namespace
    path "kubernetes/creds/${ns}-deployer" {
      capabilities = ["read"]
    }
    %{endfor}
  EOT
}

# =============================================================================
# Transit Secrets Engine — SOPS State Encryption
# =============================================================================

resource "vault_mount" "transit" {
  path       = "transit"
  type       = "transit"
  depends_on = [helm_release.vault]
}

# --- SOPS State Encryption — Per-Stack Transit Keys ---
# Namespace-owners get Transit keys for their stacks only.
# Admin gets a wildcard policy via vault-admin.

resource "vault_transit_secret_backend_key" "sops_user_stack" {
  for_each = nonsensitive(local.user_namespaces)

  backend    = vault_mount.transit.path
  name       = "sops-state-${each.value}"
  depends_on = [vault_mount.transit]
}

resource "vault_policy" "sops_user" {
  for_each = nonsensitive({
    for name, user in local.k8s_users : name => user
    if user.role == "namespace-owner"
  })

  name = "sops-user-${each.key}"
  policy = join("\n", [
    for ns in each.value.namespaces : <<-EOT
    path "transit/encrypt/sops-state-${ns}" { capabilities = ["update"] }
    path "transit/decrypt/sops-state-${ns}" { capabilities = ["update"] }
    path "transit/keys/sops-state-${ns}"    { capabilities = ["read"] }
    EOT
  ])
}

resource "vault_identity_group" "sops_user" {
  for_each = nonsensitive({
    for name, user in local.k8s_users : name => user
    if user.role == "namespace-owner"
  })

  name     = "sops-${each.key}"
  type     = "external"
  policies = [vault_policy.sops_user[each.key].name]
}

resource "vault_identity_group_alias" "sops_user" {
  for_each = nonsensitive({
    for name, user in local.k8s_users : name => user
    if user.role == "namespace-owner"
  })

  name           = "sops-${each.key}"
  mount_accessor = vault_jwt_auth_backend.oidc.accessor
  canonical_id   = vault_identity_group.sops_user[each.key].id
}

resource "vault_identity_entity" "namespace_owner" {
  for_each = nonsensitive({
    for name, user in local.k8s_users : name => user
    if user.role == "namespace-owner"
  })

  name     = each.key
  policies = [vault_policy.namespace_owner[each.key].name, vault_policy.sops_user[each.key].name]
}

resource "vault_identity_entity_alias" "namespace_owner" {
  for_each = nonsensitive({
    for name, user in local.k8s_users : name => user
    if user.role == "namespace-owner"
  })

  name           = each.value.email
  mount_accessor = vault_jwt_auth_backend.oidc.accessor
  canonical_id   = vault_identity_entity.namespace_owner[each.key].id
}

resource "kubernetes_role" "user_deployer" {
  for_each = nonsensitive(local.user_namespaces)

  metadata {
    name      = "${each.value}-deployer"
    namespace = each.value
  }
  rule {
    api_groups = ["apps"]
    resources  = ["deployments"]
    verbs      = ["get", "list", "patch", "update"]
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "list"]
  }

  depends_on = [kubernetes_namespace.user_namespace]
}

resource "vault_kubernetes_secret_backend_role" "user_deployer" {
  for_each = nonsensitive(local.user_namespaces)

  backend                       = vault_kubernetes_secret_backend.k8s.path
  name                          = "${each.value}-deployer"
  allowed_kubernetes_namespaces = [each.value]
  token_default_ttl             = 1800
  token_max_ttl                 = 3600
  kubernetes_role_type          = "Role"
  kubernetes_role_name          = kubernetes_role.user_deployer[each.key].metadata[0].name
}
