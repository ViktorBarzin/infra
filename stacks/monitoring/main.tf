# =============================================================================
# Monitoring Stack — Prometheus / Grafana / Loki
# =============================================================================

variable "tls_secret_name" { type = string }
variable "nfs_server" { type = string }
variable "mysql_host" { type = string }
variable "monitoring_idrac_username" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "platform"
}

data "vault_kv_secret_v2" "viktor" {
  mount = "secret"
  name  = "viktor"
}

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
  grafana_admin_password        = data.vault_kv_secret_v2.secrets.data["grafana_admin_password"]
  registry_user                 = data.vault_kv_secret_v2.viktor.data["registry_user"]
  registry_password             = data.vault_kv_secret_v2.viktor.data["registry_password"]
  tier                          = local.tiers.cluster
}
