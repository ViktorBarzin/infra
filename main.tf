variable "prod" {
  type    = bool
  default = false
}
variable "proxmox_pm_api_url" { type = string }
variable "proxmox_pm_api_token_id" { type = string }
variable "proxmox_pm_api_token_secret" { type = string }
variable "k8s_join_command" { type = string }
variable "vm_wizard_password" { type = string }
variable "proxmox_host" { type = string }
variable "ssh_private_key" {
  type    = string
  default = ""
}
variable "ssh_public_key" {
  type    = string
  default = ""
}
variable "tls_secret_name" {}
variable "tls_crt" {
  default = ""
}
variable "tls_key" {
  default = ""
}
variable "client_certificate_secret_name" {}
variable "mailserver_accounts" {}
variable "mailserver_aliases" {}
variable "mailserver_opendkim_key" {}
variable "mailserver_roundcubemail_db_password" { type = string }
variable "mailserver_sasl_passwd" {}
variable "pihole_web_password" {}
variable "webhook_handler_secret" {}
variable "wireguard_wg_0_conf" {}
variable "wireguard_firewall_sh" {}
variable "hackmd_db_password" {}
variable "bind_db_viktorbarzin_me" {}
variable "bind_db_viktorbarzin_lan" {}
variable "bind_named_conf_options" {}
variable "alertmanager_account_password" {}
variable "wireguard_wg_0_key" {}
variable "dbaas_root_password" {}
variable "dbaas_postgresql_root_password" {}
variable "dbaas_pgadmin_password" {}
variable "drone_github_client_id" {}
variable "drone_github_client_secret" {}
variable "drone_rpc_secret" {}
variable "drone_webhook_secret" {}
variable "dockerhub_registry_password" {}
variable "oauth2_proxy_client_id" {}
variable "oauth2_proxy_client_secret" {}
variable "oauth2_proxy_authenticated_emails" {}
variable "url_shortener_mysql_password" {}
variable "url_shortener_geolite_license_key" {}
variable "url_shortener_api_key" {}
variable "webhook_handler_fb_verify_token" {}
variable "webhook_handler_fb_page_token" {}
variable "webhook_handler_fb_app_secret" {}
variable "webhook_handler_git_user" {}
variable "technitium_username" {}
variable "technitium_password" {}
variable "technitium_db_password" {}
variable "webhook_handler_git_token" {}
variable "webhook_handler_ssh_key" {}
variable "monitoring_idrac_username" {}
variable "monitoring_idrac_password" {}
variable "alertmanager_slack_api_url" {}
variable "home_assistant_configuration" {}
variable "shadowsocks_password" {}
variable "finance_app_db_connection_string" {}
variable "finance_app_currency_converter_api_key" {}
variable "finance_app_graphql_api_secret" {}
variable "finance_app_gocardless_secret_key" {}
variable "finance_app_gocardless_secret_id" {}
variable "headscale_config" {}
variable "headscale_acl" {}
variable "immich_postgresql_password" {}
variable "immich_frame_api_key" {}
variable "ingress_crowdsec_api_key" {}
variable "crowdsec_enroll_key" { type = string }
variable "crowdsec_db_password" { type = string }
variable "crowdsec_dash_api_key" { type = string }
variable "crowdsec_dash_machine_id" { type = string }
variable "crowdsec_dash_machine_password" { type = string }
variable "vaultwarden_smtp_password" {}
variable "resume_database_url" {}
variable "resume_database_password" {}
variable "resume_redis_url" {}
variable "resume_auth_secret" { type = string }
variable "frigate_valchedrym_camera_credentials" { default = "" }
variable "paperless_db_password" {}
variable "diun_nfty_token" {}
variable "diun_slack_url" {}
variable "docker_config" {}
variable "nextcloud_db_password" {}
variable "homepage_credentials" {
  type = map(any)
}
variable "authentik_secret_key" {}
variable "authentik_postgres_password" {}

variable "ansible_prefix" {
  default     = "ANSIBLE_VAULT_PASSWORD_FILE=~/.ansible/vault_pass.txt ansible-playbook -i playbook/hosts.yaml playbook/linux.yml -t linux/initial_setup"
  description = "Provisioner command"
}
variable "linkwarden_postgresql_password" {}
variable "linkwarden_authentik_client_id" {}
variable "linkwarden_authentik_client_secret" {}
variable "cloudflare_api_key" {}
variable "cloudflare_email" {}
variable "cloudflare_account_id" {}
variable "cloudflare_zone_id" {}
variable "cloudflare_tunnel_id" {}
variable "public_ip" {}
variable "cloudflare_proxied_names" {}
variable "cloudflare_non_proxied_names" {}
variable "cloudflare_tunnel_token" {}
variable "owntracks_credentials" {}
variable "ollama_api_credentials" {}
variable "dawarich_database_password" {}
variable "geoapify_api_key" {}
variable "tandoor_database_password" {}
variable "n8n_postgresql_password" {}
variable "realestate_crawler_db_password" {}
variable "realestate_crawler_notification_settings" {
  type = map(string)
}
variable "kured_notify_url" {}
variable "onlyoffice_db_password" { type = string }
variable "onlyoffice_jwt_token" { type = string }
variable "xray_reality_clients" { type = list(map(string)) }
variable "xray_reality_private_key" { type = string }
variable "xray_reality_short_ids" { type = list(string) }
variable "tiny_tuya_api_key" { type = string }
variable "tiny_tuya_api_secret" { type = string }
variable "tiny_tuya_service_secret" { type = string }
variable "tiny_tuya_slack_url" { type = string }
variable "haos_api_token" { type = string }
variable "pve_password" { type = string }
variable "grafana_db_password" { type = string }
variable "grafana_admin_password" { type = string }
variable "clickhouse_password" { type = string }
variable "clickhouse_postgres_password" { type = string }
variable "wealthfolio_password_hash" { type = string }
variable "aiostreams_database_connection_string" { type = string }
variable "actualbudget_credentials" { type = map(any) }
variable "speedtest_db_password" { type = string }
variable "freedify_credentials" { type = map(any) }
variable "mcaptcha_postgresql_password" { type = string }
variable "mcaptcha_cookie_secret" { type = string }
variable "mcaptcha_captcha_salt" { type = string }
variable "openrouter_api_key" { type = string }
variable "slack_bot_token" { type = string }
variable "slack_channel" { type = string }
variable "affine_postgresql_password" { type = string }
variable "health_postgresql_password" { type = string }
variable "health_secret_key" { type = string }
variable "openclaw_ssh_key" { type = string }
variable "openclaw_skill_secrets" { type = map(string) }
variable "gemini_api_key" { type = string }
variable "llama_api_key" { type = string }
variable "brave_api_key" { type = string }
variable "modal_api_key" { type = string }
variable "coturn_turn_secret" { type = string }

variable "k8s_users" {
  type    = map(any)
  default = {}
}

variable "kube_config_path" {
  type    = string
  default = "~/.kube/config"
}

provider "kubernetes" {
  config_path = var.prod ? "" : var.kube_config_path
}

provider "helm" {
  kubernetes = {
    config_path = var.prod ? "" : var.kube_config_path
  }
}

provider "proxmox" {
  pm_api_url          = var.proxmox_pm_api_url
  pm_api_token_id     = var.proxmox_pm_api_token_id
  pm_api_token_secret = var.proxmox_pm_api_token_secret
  pm_tls_insecure     = true
}
# TODO: add DEFCON levels

# ---------------------------------------------------------------------------
# Infra modules (VM templates, docker-registry) migrated to stacks/infra/
# Manage with: cd stacks/infra && terragrunt apply
# ---------------------------------------------------------------------------

# module that provisions the proxmox host?
# make dns stateless?
# pfsense/truenas configs in code
# etcd db backup in code

# module "k8s_node5" {
#   template_name  = local.vm_template_name
#   source         = "./modules/create-vm"
#   vm_name        = "k8s-node5"
#   vmid           = 205
#   cisnippet_name = local.vm_cloud_init_snippet_name

#   vm_mac_address = "00:50:56:87:4a:2d"
#   bridge         = "vmbr1"
#   vlan_tag       = "20"
# }

# module "k8s_master" {
#   source              = "./modules/create-vm"
#   vm_name             = "k8s-master"
#   vm_mac_address      = "00:50:56:b0:a1:39"
#   network             = "dKubernetes"
#   provisioner_command = "${var.ansible_prefix} -t linux/k8s/master -e hostname=k8s-master"

#   vsphere_password      = var.vsphere_password
#   vsphere_user          = var.vsphere_user
#   vsphere_server        = var.vsphere_server
#   vsphere_datastore     = "r730-datastore"
#   vsphere_resource_pool = "R730"

# }
# module "k8s_node1" {
#   source              = "./modules/create-vm"
#   vm_name             = "k8s-node1"
#   vm_mac_address      = "00:50:56:b0:e0:c9"
#   network             = "dKubernetes"
#   provisioner_command = "${var.ansible_prefix} -t linux/k8s/node -e hostname=k8s-node1 -e k8s_master='wizard@${module.k8s_master.guest_ip}'"

#   vsphere_password      = var.vsphere_password
#   vsphere_user          = var.vsphere_user
#   vsphere_server        = var.vsphere_server
#   vsphere_datastore     = "r730-datastore"
#   vsphere_resource_pool = "R730"

# }

# module "k8s_node2" {
#   source              = "./modules/create-vm"
#   vm_name             = "k8s-node2"
#   vm_mac_address      = "00:50:56:b0:a1:36"
#   network             = "dKubernetes"
#   provisioner_command = "${var.ansible_prefix} -t linux/k8s/node -e hostname=k8s-node2 -e k8s_master='wizard@${module.k8s_master.guest_ip}'"

#   vsphere_password      = var.vsphere_password
#   vsphere_user          = var.vsphere_user
#   vsphere_server        = var.vsphere_server
#   vsphere_datastore     = "r730-datastore"
#   vsphere_resource_pool = "R730"
# }

# module "k8s_node3" {
#   source              = "./modules/create-vm"
#   vm_name             = "k8s-node3"
#   vm_mac_address      = "00:50:56:b0:a1:37"
#   network             = "dKubernetes"
#   provisioner_command = "${var.ansible_prefix} -t linux/k8s/node -e hostname=k8s-node3 -e k8s_master='wizard@${module.k8s_master.guest_ip}'"

#   vsphere_password      = var.vsphere_password
#   vsphere_user          = var.vsphere_user
#   vsphere_server        = var.vsphere_server
#   vsphere_datastore     = "r730-datastore"
#   vsphere_resource_pool = "R730"
# }

# module "k8s_node4" {
#   source         = "./modules/create-vm"
#   vm_name        = "k8s-node4"
#   vmid           = 204
#   template_name  = local.vm_template_name
#   cisnippet_name = local.vm_cloud_init_snippet_name

#   vm_mac_address = "00:50:56:b0:a1:38"
#   bridge         = "vmbr1"
#   vlan_tag       = "20"
# }

# module "k8s_node5" {
#   source              = "./modules/create-vm"
#   vm_name             = "k8s-node5"
#   vm_mac_address      = "00:50:56:b0:a1:40"
#   network             = "dKubernetes"
#   provisioner_command = "${var.ansible_prefix} -t linux/k8s/node -e hostname=k8s-node5 -e k8s_master='wizard@${module.k8s_master.guest_ip}'"

#   vsphere_password      = var.vsphere_password
#   vsphere_user          = var.vsphere_user
#   vsphere_server        = var.vsphere_server
#   vsphere_datastore     = "r730-datastore"
#   vsphere_resource_pool = "R730"

# }
# module "devvm" {
#   source         = "./modules/create-vm"
#   vm_name        = "devvm"
#   vm_mac_address = "00:50:56:b0:a1:41"
#   network        = "dKubernetes"
#   # provisioner_command = "${var.ansible_prefix} -t linux/k8s/node -e hostname=k8s-node5 -e k8s_master='wizard@${module.k8s_master.guest_ip}'"

#   vsphere_password      = var.vsphere_password
#   vsphere_user          = var.vsphere_user
#   vsphere_server        = var.vsphere_server
#   vsphere_datastore     = "r730-datastore"
#   vsphere_resource_pool = "R730"
# }

# resource "null_resource" "test" {
#   provisioner "local-exec" {
#     working_dir = "/home/viktor/"
#     command     = "ANSIBLE_VAULT_PASSWORD_FILE=~/.ansible/vault_pass.txt ansible-playbook -i playbook/hosts.yaml playbook/linux.yml -t linux/k8s/node -e host='10.0.40.126'"
#   }
# }

# ---------------------------------------------------------------------------
# The kubernetes_cluster module (modules/kubernetes/) has been migrated to
# individual Terragrunt stacks under stacks/.
# See stacks/<service>/main.tf for each service's configuration.
# ---------------------------------------------------------------------------


