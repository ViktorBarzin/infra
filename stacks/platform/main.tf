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

# --- Core ---
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

# --- dbaas ---
variable "dbaas_root_password" {
  type = string
  sensitive = true
}
variable "dbaas_postgresql_root_password" {
  type = string
  sensitive = true
}
variable "dbaas_pgadmin_password" {
  type = string
  sensitive = true
}

# --- traefik ---
variable "ingress_crowdsec_api_key" {
  type = string
  sensitive = true
}
variable "auth_fallback_htpasswd" {
  type      = string
  sensitive = true
  default   = ""
}

# --- technitium ---
variable "technitium_db_password" {
  type = string
  sensitive = true
}
variable "homepage_credentials" {
  type = map(any)
  sensitive = true
}

# --- headscale ---
variable "headscale_config" { type = string }
variable "headscale_acl" { type = string }
variable "k8s_ca_cert" {
  type    = string
  default = ""
}

# --- authentik / rbac / k8s-portal ---
variable "authentik_secret_key" {
  type = string
  sensitive = true
}
variable "authentik_postgres_password" {
  type = string
  sensitive = true
}
variable "k8s_users" {
  type    = map(any)
  default = {}
}
variable "ssh_private_key" {
  type      = string
  default   = ""
  sensitive = true
}

# --- crowdsec ---
variable "crowdsec_enroll_key" { type = string }
variable "crowdsec_db_password" {
  type = string
  sensitive = true
}
variable "crowdsec_dash_api_key" {
  type = string
  sensitive = true
}
variable "crowdsec_dash_machine_id" { type = string }
variable "crowdsec_dash_machine_password" {
  type = string
  sensitive = true
}
variable "alertmanager_slack_api_url" { type = string }

# --- cloudflared ---
variable "cloudflare_api_key" {
  type = string
  sensitive = true
}
variable "cloudflare_email" { type = string }
variable "cloudflare_account_id" { type = string }
variable "cloudflare_zone_id" { type = string }
variable "cloudflare_tunnel_id" { type = string }
variable "public_ip" { type = string }
variable "cloudflare_proxied_names" {}
variable "cloudflare_non_proxied_names" {}
variable "cloudflare_tunnel_token" {
  type = string
  sensitive = true
}

# --- monitoring ---
variable "alertmanager_account_password" {
  type = string
  sensitive = true
}
variable "monitoring_idrac_username" { type = string }
variable "monitoring_idrac_password" {
  type = string
  sensitive = true
}
variable "tiny_tuya_service_secret" {
  type = string
  sensitive = true
}
variable "haos_api_token" {
  type = string
  sensitive = true
}
variable "pve_password" {
  type = string
  sensitive = true
}
variable "grafana_db_password" {
  type = string
  sensitive = true
}
variable "grafana_admin_password" {
  type = string
  sensitive = true
}

# --- vaultwarden ---
variable "vaultwarden_smtp_password" {
  type = string
  sensitive = true
}

# --- wireguard ---
variable "wireguard_wg_0_conf" { type = string }
variable "wireguard_wg_0_key" { type = string }
variable "wireguard_firewall_sh" { type = string }

# --- xray ---
variable "xray_reality_clients" { type = list(map(string)) }
variable "xray_reality_private_key" {
  type = string
  sensitive = true
}
variable "xray_reality_short_ids" { type = list(string) }

# --- mailserver ---
variable "mailserver_accounts" {}
variable "mailserver_aliases" {}
variable "mailserver_opendkim_key" {}
variable "mailserver_sasl_passwd" {}
variable "mailserver_roundcubemail_db_password" {
  type = string
  sensitive = true
}

# --- infra-maintenance ---
variable "webhook_handler_git_user" { type = string }
variable "webhook_handler_git_token" {
  type = string
  sensitive = true
}
variable "technitium_username" { type = string }
variable "technitium_password" {
  type = string
  sensitive = true
}

# --- iscsi-csi ---
variable "truenas_api_key" {
  type      = string
  sensitive = true
}
variable "truenas_ssh_private_key" {
  type      = string
  sensitive = true
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
  dbaas_root_password      = var.dbaas_root_password
  postgresql_root_password = var.dbaas_postgresql_root_password
  pgadmin_password         = var.dbaas_pgadmin_password
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
  crowdsec_api_key       = var.ingress_crowdsec_api_key
  redis_host             = var.redis_host
  tls_secret_name        = var.tls_secret_name
  auth_fallback_htpasswd = var.auth_fallback_htpasswd
}

# -----------------------------------------------------------------------------
# Technitium — DNS server
# -----------------------------------------------------------------------------
module "technitium" {
  source                 = "./modules/technitium"
  tls_secret_name        = var.tls_secret_name
  nfs_server             = var.nfs_server
  mysql_host             = var.mysql_host
  homepage_token         = var.homepage_credentials["technitium"]["token"]
  technitium_db_password = var.technitium_db_password
  technitium_username    = var.technitium_username
  technitium_password    = var.technitium_password
  tier                   = local.tiers.core
}

# -----------------------------------------------------------------------------
# Headscale — Tailscale control server
# -----------------------------------------------------------------------------
module "headscale" {
  source           = "./modules/headscale"
  tls_secret_name  = var.tls_secret_name
  nfs_server       = var.nfs_server
  headscale_config = var.headscale_config
  headscale_acl    = var.headscale_acl
  tier             = local.tiers.core
}

# -----------------------------------------------------------------------------
# Authentik — Identity provider (SSO)
# -----------------------------------------------------------------------------
module "authentik" {
  source            = "./modules/authentik"
  tier              = local.tiers.cluster
  tls_secret_name   = var.tls_secret_name
  secret_key        = var.authentik_secret_key
  postgres_password = var.authentik_postgres_password
  redis_host        = var.redis_host
}

# -----------------------------------------------------------------------------
# RBAC — Kubernetes OIDC RBAC (depends on Authentik)
# -----------------------------------------------------------------------------
module "rbac" {
  source          = "./modules/rbac"
  tier            = local.tiers.cluster
  tls_secret_name = var.tls_secret_name
  k8s_users       = var.k8s_users
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
  homepage_username              = var.homepage_credentials["crowdsec"]["username"]
  homepage_password              = var.homepage_credentials["crowdsec"]["password"]
  enroll_key                     = var.crowdsec_enroll_key
  db_password                    = var.crowdsec_db_password
  crowdsec_dash_api_key          = var.crowdsec_dash_api_key
  crowdsec_dash_machine_id       = var.crowdsec_dash_machine_id
  crowdsec_dash_machine_password = var.crowdsec_dash_machine_password
  slack_webhook_url              = var.alertmanager_slack_api_url
}

# -----------------------------------------------------------------------------
# Monitoring — Prometheus / Grafana / Loki stack
# -----------------------------------------------------------------------------
module "monitoring" {
  source                        = "./modules/monitoring"
  tls_secret_name               = var.tls_secret_name
  nfs_server                    = var.nfs_server
  mysql_host                    = var.mysql_host
  alertmanager_account_password = var.alertmanager_account_password
  idrac_username                = var.monitoring_idrac_username
  idrac_password                = var.monitoring_idrac_password
  alertmanager_slack_api_url    = var.alertmanager_slack_api_url
  tiny_tuya_service_secret      = var.tiny_tuya_service_secret
  haos_api_token                = var.haos_api_token
  pve_password                  = var.pve_password
  grafana_db_password           = var.grafana_db_password
  grafana_admin_password        = var.grafana_admin_password
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
  smtp_password   = var.vaultwarden_smtp_password
  tier            = local.tiers.edge
}

# -----------------------------------------------------------------------------
# Reverse Proxy — Generic reverse proxy
# -----------------------------------------------------------------------------
module "reverse-proxy" {
  source                 = "./modules/reverse_proxy"
  tls_secret_name        = var.tls_secret_name
  truenas_homepage_token = var.homepage_credentials["reverse_proxy"]["truenas_token"]
  pfsense_homepage_token = var.homepage_credentials["reverse_proxy"]["pfsense_token"]
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
  source                 = "./modules/iscsi-csi"
  tier                   = local.tiers.cluster
  truenas_host           = var.nfs_server # Same TrueNAS host
  truenas_api_key        = var.truenas_api_key
  truenas_ssh_private_key = var.truenas_ssh_private_key
}

# -----------------------------------------------------------------------------
# CNPG — CloudNativePG Operator + local-path-provisioner for database storage
# -----------------------------------------------------------------------------
module "cnpg" {
  source = "./modules/cnpg"
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
  wg_0_conf       = var.wireguard_wg_0_conf
  wg_0_key        = var.wireguard_wg_0_key
  firewall_sh     = var.wireguard_firewall_sh
  tier            = local.tiers.core
}

# -----------------------------------------------------------------------------
# Xray — Proxy/tunnel
# -----------------------------------------------------------------------------
module "xray" {
  source          = "./modules/xray"
  tls_secret_name = var.tls_secret_name
  tier            = local.tiers.core

  xray_reality_clients     = var.xray_reality_clients
  xray_reality_private_key = var.xray_reality_private_key
  xray_reality_short_ids   = var.xray_reality_short_ids
}

# -----------------------------------------------------------------------------
# Mailserver — docker-mailserver
# -----------------------------------------------------------------------------
module "mailserver" {
  source                  = "./modules/mailserver"
  tls_secret_name         = var.tls_secret_name
  nfs_server              = var.nfs_server
  mysql_host              = var.mysql_host
  mailserver_accounts     = var.mailserver_accounts
  postfix_account_aliases = var.mailserver_aliases
  opendkim_key            = var.mailserver_opendkim_key
  sasl_passwd             = var.mailserver_sasl_passwd
  roundcube_db_password   = var.mailserver_roundcubemail_db_password
  tier                    = local.tiers.edge
}

# -----------------------------------------------------------------------------
# Cloudflared — Cloudflare tunnel + DNS records
# -----------------------------------------------------------------------------
module "cloudflared" {
  source          = "./modules/cloudflared"
  tier            = local.tiers.core
  tls_secret_name = var.tls_secret_name

  cloudflare_api_key           = var.cloudflare_api_key
  cloudflare_email             = var.cloudflare_email
  cloudflare_account_id        = var.cloudflare_account_id
  cloudflare_zone_id           = var.cloudflare_zone_id
  cloudflare_tunnel_id         = var.cloudflare_tunnel_id
  public_ip                    = var.public_ip
  cloudflare_proxied_names     = var.cloudflare_proxied_names
  cloudflare_non_proxied_names = var.cloudflare_non_proxied_names
  cloudflare_tunnel_token      = var.cloudflare_tunnel_token
}

# -----------------------------------------------------------------------------
# Infra Maintenance — Automated maintenance jobs
# -----------------------------------------------------------------------------
module "infra-maintenance" {
  source              = "./modules/infra-maintenance"
  nfs_server          = var.nfs_server
  git_user            = var.webhook_handler_git_user
  git_token           = var.webhook_handler_git_token
  technitium_username = var.technitium_username
  technitium_password = var.technitium_password
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
