# =============================================================================
# Monitoring Stack — Prometheus / Grafana / Loki
# =============================================================================

variable "tls_secret_name" { type = string }
variable "nfs_server" { type = string }
variable "mysql_host" { type = string }
variable "postgresql_host" { type = string }
variable "monitoring_idrac_username" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "platform"
}

data "vault_kv_secret_v2" "viktor" {
  mount = "secret"
  name  = "viktor"
}

# Basic-auth credentials for the dawarich-sidekiq-metrics scrape job. The same
# pair reaches the pod through the dawarich-secrets ExternalSecret, so Vault is
# the single source and neither side can drift.
data "vault_kv_secret_v2" "dawarich" {
  mount = "secret"
  name  = "dawarich"
}

module "monitoring" {
  source                         = "./modules/monitoring"
  tls_secret_name                = var.tls_secret_name
  nfs_server                     = var.nfs_server
  mysql_host                     = var.mysql_host
  postgresql_host                = var.postgresql_host
  dbaas_postgresql_root_password = data.vault_kv_secret_v2.secrets.data["dbaas_postgresql_root_password"]
  alertmanager_account_password  = data.vault_kv_secret_v2.secrets.data["alertmanager_account_password"]
  idrac_username                 = var.monitoring_idrac_username
  idrac_password                 = data.vault_kv_secret_v2.secrets.data["monitoring_idrac_password"]
  alertmanager_slack_api_url     = data.vault_kv_secret_v2.secrets.data["alertmanager_slack_api_url"]
  tiny_tuya_service_secret       = data.vault_kv_secret_v2.secrets.data["tiny_tuya_service_secret"]
  dawarich_metrics_username      = data.vault_kv_secret_v2.dawarich.data["metrics_username"]
  dawarich_metrics_password      = data.vault_kv_secret_v2.dawarich.data["metrics_password"]
  haos_api_token                 = data.vault_kv_secret_v2.secrets.data["haos_api_token"]
  pve_password                   = data.vault_kv_secret_v2.secrets.data["pve_password"]
  grafana_admin_password         = data.vault_kv_secret_v2.secrets.data["grafana_admin_password"]
  kube_config_path               = var.kube_config_path
  registry_user                  = data.vault_kv_secret_v2.viktor.data["registry_user"]
  registry_password              = data.vault_kv_secret_v2.viktor.data["registry_password"]
  # try() so apply succeeds before the Vault key is populated during Phase 0
  # bootstrap (see docs/runbooks/forgejo-registry-setup.md). Empty token =
  # probe will report an auth failure and fire RegistryCatalogInaccessible —
  # that's the intended visible-broken state until the PAT is created.
  forgejo_pull_token = try(data.vault_kv_secret_v2.viktor.data["forgejo_pull_token"], "")
  tier               = local.tiers.cluster
}
