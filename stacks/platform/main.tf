# =============================================================================
# Platform Stack — Core & Cluster Services
# =============================================================================
#
# This stack groups ~22 core/cluster services that form the platform layer.
# These services are always present (no DEFCON gating) and provide the
# foundational infrastructure that application stacks depend on.
#
# Services included:
#   metallb, dbaas, cloudflared, infra-maintenance,
#   redis, traefik, technitium, headscale, authentik, rbac, k8s-portal,
#   crowdsec, monitoring, vaultwarden, reverse-proxy, metrics-server, vpa,
#   nvidia, kyverno, uptime-kuma, wireguard, xray, mailserver
# =============================================================================

# -----------------------------------------------------------------------------
# Tier Definitions
# -----------------------------------------------------------------------------

# =============================================================================
# Variable Declarations
# =============================================================================

# --- Core (non-secret, from config.tfvars) ---
variable "tls_secret_name" {
  type = string
}
variable "nfs_server" { type = string }
variable "redis_host" { type = string }
variable "postgresql_host" { type = string }
variable "mysql_host" { type = string }
variable "ollama_host" { type = string }
variable "mail_host" { type = string }
variable "prod" {
  type    = bool
  default = false
}
variable "k8s_ca_cert" {
  type    = string
  default = ""
}
variable "ssh_private_key" {
  type      = string
  default   = ""
  sensitive = true
}
variable "cloudflare_email" { type = string }
variable "cloudflare_account_id" { type = string }
variable "cloudflare_zone_id" { type = string }
variable "cloudflare_tunnel_id" { type = string }
variable "public_ip" { type = string }
variable "cloudflare_proxied_names" {}
variable "cloudflare_non_proxied_names" {}
variable "monitoring_idrac_username" { type = string }

# --- Vault KV secrets ---
data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "platform"
}

locals {
  homepage_credentials   = jsondecode(data.vault_kv_secret_v2.secrets.data["homepage_credentials"])
  k8s_users              = jsondecode(data.vault_kv_secret_v2.secrets.data["k8s_users"])
  xray_reality_clients   = jsondecode(data.vault_kv_secret_v2.secrets.data["xray_reality_clients"])
  xray_reality_short_ids = jsondecode(data.vault_kv_secret_v2.secrets.data["xray_reality_short_ids"])
  mailserver_accounts    = jsondecode(data.vault_kv_secret_v2.secrets.data["mailserver_accounts"])
  mailserver_aliases     = jsondecode(data.vault_kv_secret_v2.secrets.data["mailserver_aliases"])
  mailserver_opendkim_key = jsondecode(data.vault_kv_secret_v2.secrets.data["mailserver_opendkim_key"])
  mailserver_sasl_passwd  = jsondecode(data.vault_kv_secret_v2.secrets.data["mailserver_sasl_passwd"])
}

# =============================================================================
# Module Calls
# =============================================================================

# -----------------------------------------------------------------------------
# MetalLB — L2 load balancer
# -----------------------------------------------------------------------------
module "metallb" {
  source = "./modules/metallb"
  tier   = local.tiers.core
}

# -----------------------------------------------------------------------------
# DBaaS — MySQL + PostgreSQL + pgAdmin
# -----------------------------------------------------------------------------
module "dbaas" {
  source                   = "./modules/dbaas"
  prod                     = var.prod
  tls_secret_name          = var.tls_secret_name
  nfs_server               = var.nfs_server
  dbaas_root_password      = data.vault_kv_secret_v2.secrets.data["dbaas_root_password"]
  postgresql_root_password = data.vault_kv_secret_v2.secrets.data["dbaas_postgresql_root_password"]
  pgadmin_password         = data.vault_kv_secret_v2.secrets.data["dbaas_pgadmin_password"]
  kube_config_path         = var.kube_config_path
  tier                     = local.tiers.cluster
}

# -----------------------------------------------------------------------------
# Redis — Shared Redis instance
# -----------------------------------------------------------------------------
module "redis" {
  source          = "./modules/redis"
  tls_secret_name = var.tls_secret_name
  nfs_server      = var.nfs_server
  tier            = local.tiers.cluster
}

# -----------------------------------------------------------------------------
# Traefik — Ingress controller (Helm)
# -----------------------------------------------------------------------------
module "traefik" {
  source                 = "./modules/traefik"
  tier                   = local.tiers.core
  crowdsec_api_key       = data.vault_kv_secret_v2.secrets.data["ingress_crowdsec_api_key"]
  redis_host             = var.redis_host
  tls_secret_name        = var.tls_secret_name
  auth_fallback_htpasswd = data.vault_kv_secret_v2.secrets.data["auth_fallback_htpasswd"]
}

# -----------------------------------------------------------------------------
# Technitium — DNS server
# -----------------------------------------------------------------------------
module "technitium" {
  source                 = "./modules/technitium"
  tls_secret_name        = var.tls_secret_name
  nfs_server             = var.nfs_server
  mysql_host             = var.mysql_host
  homepage_token         = local.homepage_credentials["technitium"]["token"]
  technitium_db_password = data.vault_kv_secret_v2.secrets.data["technitium_db_password"]
  technitium_username    = data.vault_kv_secret_v2.secrets.data["technitium_username"]
  technitium_password    = data.vault_kv_secret_v2.secrets.data["technitium_password"]
  tier                   = local.tiers.core
}

# -----------------------------------------------------------------------------
# Headscale — Tailscale control server
# -----------------------------------------------------------------------------
module "headscale" {
  source           = "./modules/headscale"
  tls_secret_name  = var.tls_secret_name
  nfs_server       = var.nfs_server
  headscale_config = data.vault_kv_secret_v2.secrets.data["headscale_config"]
  headscale_acl    = data.vault_kv_secret_v2.secrets.data["headscale_acl"]
  homepage_token   = try(local.homepage_credentials["headscale"]["api_key"], "")
  tier             = local.tiers.core
}

# -----------------------------------------------------------------------------
# Authentik — Identity provider (SSO)
# -----------------------------------------------------------------------------
module "authentik" {
  source            = "./modules/authentik"
  tier              = local.tiers.cluster
  tls_secret_name   = var.tls_secret_name
  secret_key        = data.vault_kv_secret_v2.secrets.data["authentik_secret_key"]
  postgres_password = data.vault_kv_secret_v2.secrets.data["authentik_postgres_password"]
  redis_host        = var.redis_host
  homepage_token    = try(local.homepage_credentials["authentik"]["token"], "")
}

# -----------------------------------------------------------------------------
# RBAC — Kubernetes OIDC RBAC (depends on Authentik)
# -----------------------------------------------------------------------------
module "rbac" {
  source          = "./modules/rbac"
  tier            = local.tiers.cluster
  tls_secret_name = var.tls_secret_name
  k8s_users       = local.k8s_users
  ssh_private_key = var.ssh_private_key
}

# -----------------------------------------------------------------------------
# K8s Portal — Self-service Kubernetes portal (depends on Authentik)
# -----------------------------------------------------------------------------
module "k8s-portal" {
  source          = "./modules/k8s-portal"
  tier            = local.tiers.edge
  tls_secret_name = var.tls_secret_name
  k8s_ca_cert     = var.k8s_ca_cert
}

# -----------------------------------------------------------------------------
# CrowdSec — Security/WAF
# -----------------------------------------------------------------------------
module "crowdsec" {
  source                         = "./modules/crowdsec"
  tier                           = local.tiers.cluster
  tls_secret_name                = var.tls_secret_name
  mysql_host                     = var.mysql_host
  homepage_username              = local.homepage_credentials["crowdsec"]["username"]
  homepage_password              = local.homepage_credentials["crowdsec"]["password"]
  enroll_key                     = data.vault_kv_secret_v2.secrets.data["crowdsec_enroll_key"]
  db_password                    = data.vault_kv_secret_v2.secrets.data["crowdsec_db_password"]
  crowdsec_dash_api_key          = data.vault_kv_secret_v2.secrets.data["crowdsec_dash_api_key"]
  crowdsec_dash_machine_id       = data.vault_kv_secret_v2.secrets.data["crowdsec_dash_machine_id"]
  crowdsec_dash_machine_password = data.vault_kv_secret_v2.secrets.data["crowdsec_dash_machine_password"]
  slack_webhook_url              = data.vault_kv_secret_v2.secrets.data["alertmanager_slack_api_url"]
}

# -----------------------------------------------------------------------------
# Monitoring — Prometheus / Grafana / Loki stack
# -----------------------------------------------------------------------------
module "monitoring" {
  source                        = "./modules/monitoring"
  tls_secret_name               = var.tls_secret_name
  nfs_server                    = var.nfs_server
  mysql_host                    = var.mysql_host
  alertmanager_account_password = data.vault_kv_secret_v2.secrets.data["alertmanager_account_password"]
  idrac_username                = var.monitoring_idrac_username
  idrac_password                = data.vault_kv_secret_v2.secrets.data["monitoring_idrac_password"]
  alertmanager_slack_api_url    = data.vault_kv_secret_v2.secrets.data["alertmanager_slack_api_url"]
  tiny_tuya_service_secret      = data.vault_kv_secret_v2.secrets.data["tiny_tuya_service_secret"]
  haos_api_token                = data.vault_kv_secret_v2.secrets.data["haos_api_token"]
  pve_password                  = data.vault_kv_secret_v2.secrets.data["pve_password"]
  grafana_db_password           = data.vault_kv_secret_v2.secrets.data["grafana_db_password"]
  grafana_admin_password        = data.vault_kv_secret_v2.secrets.data["grafana_admin_password"]
  tier                          = local.tiers.cluster
}

# -----------------------------------------------------------------------------
# Vaultwarden — Password manager
# -----------------------------------------------------------------------------
module "vaultwarden" {
  source          = "./modules/vaultwarden"
  tls_secret_name = var.tls_secret_name
  nfs_server      = var.nfs_server
  mail_host       = var.mail_host
  smtp_password   = data.vault_kv_secret_v2.secrets.data["vaultwarden_smtp_password"]
  tier            = local.tiers.edge
}

# -----------------------------------------------------------------------------
# Reverse Proxy — Generic reverse proxy
# -----------------------------------------------------------------------------
module "reverse-proxy" {
  source                 = "./modules/reverse_proxy"
  tls_secret_name        = var.tls_secret_name
  truenas_homepage_token = local.homepage_credentials["reverse_proxy"]["truenas_token"]
  pfsense_homepage_token = local.homepage_credentials["reverse_proxy"]["pfsense_token"]
  haos_homepage_token    = try(local.homepage_credentials["home_assistant"]["token"], "")
}

# -----------------------------------------------------------------------------
# Metrics Server — Kubernetes metrics
# -----------------------------------------------------------------------------
module "metrics-server" {
  source          = "./modules/metrics-server"
  tier            = local.tiers.cluster
  tls_secret_name = var.tls_secret_name
}

# -----------------------------------------------------------------------------
# VPA + Goldilocks — Vertical Pod Autoscaler & resource dashboard
# -----------------------------------------------------------------------------
module "vpa" {
  source          = "./modules/vpa"
  tls_secret_name = var.tls_secret_name
  tier            = local.tiers.cluster
}

# -----------------------------------------------------------------------------
# NFS CSI — CSI driver for NFS with soft mount options (no stale mount hangs)
# -----------------------------------------------------------------------------
module "nfs-csi" {
  source     = "./modules/nfs-csi"
  tier       = local.tiers.cluster
  nfs_server = var.nfs_server
}

# -----------------------------------------------------------------------------
# iSCSI CSI — democratic-csi for TrueNAS iSCSI (database storage)
# -----------------------------------------------------------------------------
module "iscsi-csi" {
  source                  = "./modules/iscsi-csi"
  tier                    = local.tiers.cluster
  truenas_host            = var.nfs_server # Same TrueNAS host
  truenas_api_key         = data.vault_kv_secret_v2.secrets.data["truenas_api_key"]
  truenas_ssh_private_key = data.vault_kv_secret_v2.secrets.data["truenas_ssh_private_key"]
}

# -----------------------------------------------------------------------------
# CNPG — CloudNativePG Operator + local-path-provisioner for database storage
# -----------------------------------------------------------------------------
module "cnpg" {
  source = "./modules/cnpg"
  tier   = local.tiers.cluster
}

# -----------------------------------------------------------------------------
# Sealed Secrets — encrypts secrets for safe git storage
# -----------------------------------------------------------------------------
module "sealed-secrets" {
  source = "./modules/sealed-secrets"
  tier   = local.tiers.cluster
}

# -----------------------------------------------------------------------------
# NVIDIA — GPU device plugin
# -----------------------------------------------------------------------------
module "nvidia" {
  source          = "./modules/nvidia"
  tls_secret_name = var.tls_secret_name
  tier            = local.tiers.gpu
}

# -----------------------------------------------------------------------------
# Kyverno — Policy engine
# -----------------------------------------------------------------------------
module "kyverno" {
  source = "./modules/kyverno"
}

# -----------------------------------------------------------------------------
# Uptime Kuma — Status monitoring
# -----------------------------------------------------------------------------
module "uptime-kuma" {
  source          = "./modules/uptime-kuma"
  tls_secret_name = var.tls_secret_name
  nfs_server      = var.nfs_server
  tier            = local.tiers.cluster
}

# -----------------------------------------------------------------------------
# WireGuard — VPN server
# -----------------------------------------------------------------------------
module "wireguard" {
  source          = "./modules/wireguard"
  tls_secret_name = var.tls_secret_name
  wg_0_conf       = data.vault_kv_secret_v2.secrets.data["wireguard_wg_0_conf"]
  wg_0_key        = data.vault_kv_secret_v2.secrets.data["wireguard_wg_0_key"]
  firewall_sh     = data.vault_kv_secret_v2.secrets.data["wireguard_firewall_sh"]
  tier            = local.tiers.core
}

# -----------------------------------------------------------------------------
# Xray — Proxy/tunnel
# -----------------------------------------------------------------------------
module "xray" {
  source          = "./modules/xray"
  tls_secret_name = var.tls_secret_name
  tier            = local.tiers.core

  xray_reality_clients     = local.xray_reality_clients
  xray_reality_private_key = data.vault_kv_secret_v2.secrets.data["xray_reality_private_key"]
  xray_reality_short_ids   = local.xray_reality_short_ids
}

# -----------------------------------------------------------------------------
# Mailserver — docker-mailserver
# -----------------------------------------------------------------------------
module "mailserver" {
  source                  = "./modules/mailserver"
  tls_secret_name         = var.tls_secret_name
  nfs_server              = var.nfs_server
  mysql_host              = var.mysql_host
  mailserver_accounts     = local.mailserver_accounts
  postfix_account_aliases = local.mailserver_aliases
  opendkim_key            = local.mailserver_opendkim_key
  sasl_passwd             = local.mailserver_sasl_passwd
  roundcube_db_password   = data.vault_kv_secret_v2.secrets.data["mailserver_roundcubemail_db_password"]
  tier                    = local.tiers.edge
}

# -----------------------------------------------------------------------------
# Cloudflared — Cloudflare tunnel + DNS records
# -----------------------------------------------------------------------------
module "cloudflared" {
  source          = "./modules/cloudflared"
  tier            = local.tiers.core
  tls_secret_name = var.tls_secret_name

  cloudflare_api_key           = data.vault_kv_secret_v2.secrets.data["cloudflare_api_key"]
  cloudflare_email             = var.cloudflare_email
  cloudflare_account_id        = var.cloudflare_account_id
  cloudflare_zone_id           = var.cloudflare_zone_id
  cloudflare_tunnel_id         = var.cloudflare_tunnel_id
  public_ip                    = var.public_ip
  cloudflare_proxied_names     = var.cloudflare_proxied_names
  cloudflare_non_proxied_names = var.cloudflare_non_proxied_names
  cloudflare_tunnel_token      = data.vault_kv_secret_v2.secrets.data["cloudflare_tunnel_token"]
}

# -----------------------------------------------------------------------------
# Infra Maintenance — Automated maintenance jobs
# -----------------------------------------------------------------------------
module "infra-maintenance" {
  source              = "./modules/infra-maintenance"
  nfs_server          = var.nfs_server
  git_user            = data.vault_kv_secret_v2.secrets.data["webhook_handler_git_user"]
  git_token           = data.vault_kv_secret_v2.secrets.data["webhook_handler_git_token"]
  technitium_username = data.vault_kv_secret_v2.secrets.data["technitium_username"]
  technitium_password = data.vault_kv_secret_v2.secrets.data["technitium_password"]
}

# =============================================================================
# Outputs (consumed by service stacks via Terragrunt dependency)
# =============================================================================

output "tls_secret_name" {
  value = var.tls_secret_name
}

output "redis_host" {
  value = var.redis_host
}

output "postgresql_host" {
  value = var.postgresql_host
}

output "postgresql_port" {
  value = 5432
}

output "mysql_host" {
  value = var.mysql_host
}

output "mysql_port" {
  value = 3306
}

output "smtp_host" {
  value = var.mail_host
}

output "smtp_port" {
  value = 587
}
