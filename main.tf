variable "prod" {
  type    = bool
  default = false
}
variable "vsphere_password" {}
variable "vsphere_user" {}
variable "vsphere_server" {}
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
# variable "dockerhub_password" {}
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
variable "ingress_honeypotapikey" {}
variable "ingress_crowdsec_api_key" {}
variable "ingress_crowdsec_captcha_secret_key" {}
variable "ingress_crowdsec_captcha_site_key" {}
variable "crowdsec_enroll_key" { type = string }
variable "crowdsec_db_password" { type = string }
variable "vaultwarden_smtp_password" {}
variable "resume_database_url" {}
variable "resume_redis_url" {}
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


# data "terraform_remote_state" "foo" {
#   backend = "kubernetes"
#   config = {
#     secret_suffix     = "state"
#     namespace         = "drone"
#     in_cluster_config = var.prod
#     host              = "https://kubernetes:6443"
#     //  load_config_file  = true
#   }

#   depends_on = [module.kubernetes_cluster]
# }
provider "kubernetes" {
  config_path = var.prod ? "" : "~/.kube/config"
}

provider "helm" {
  kubernetes {
    config_path = var.prod ? "" : "~/.kube/config"
  }
}
# TODO: add DEFCON levels

# provider "proxmox" {
#   endpoint = "https://10.0.10.105:8006/api2/json"
#   username = "root@pam"
#   password = "to-change"
#   insecure = true
#   tmp_dir  = "/var/tmp"
# }

# resource "proxmox_virtual_environment_network_linux_vlan" "vlan1" {
#   node_name = "pve"
#   name      = "ens160.99"

#   comment = "VLAN 99"
# }


# resource "proxmox_vm_qemu" "k8s-master-pve" {
#   name        = "test"
#   target_node = "pve"
#   # iso         = "ubuntu-22.04.3-live-server-amd64.iso"
#   iso      = "local:iso/ubuntu-22.04.3-live-server-amd64.iso"
#   agent    = 1
#   os_type  = "ubuntu"
#   cores    = 4
#   sockets  = 1
#   cpu      = "host"
#   memory   = 2048
#   scsihw   = "virtio-scsi-pci"
#   bootdisk = "scsi0"
#   disk {
#     slot = 0
#     # set disk size here. leave it small for testing because expanding the disk takes time.
#     size     = "10G"
#     type     = "scsi"
#     storage  = "local-lvm"
#     iothread = 0
#   }
# }

# Main module to init infra from
# module "pxe_server" {
#   source  = "./modules/create-vm"
#   vm_name = "pxe-server"
#   network = "dManagementVMs"
#   # provisioner_command = "${var.ansible_prefix} -t linux/pxe-server/add-distro"
#   provisioner_command = "# no provisioner needed #" # Noop until ubuntu autoinstall is setup

#   vsphere_password = var.vsphere_password
#   vsphere_user     = var.vsphere_user
#   vsphere_server   = var.vsphere_server
#   cdrom_path       = "ISO/ubuntu-server-20.04.1.iso"
#   vm_disk_size     = 50
#   vm_mac_address   = "00:50:56:87:4a:2d"
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
#   source              = "./modules/create-vm"
#   vm_name             = "k8s-node4"
#   vm_mac_address      = "00:50:56:b0:a1:38"
#   network             = "dKubernetes"
#   provisioner_command = "${var.ansible_prefix} -t linux/k8s/node -e hostname=k8s-node4 -e k8s_master='wizard@${module.k8s_master.guest_ip}'"

#   vsphere_password      = var.vsphere_password
#   vsphere_user          = var.vsphere_user
#   vsphere_server        = var.vsphere_server
#   vsphere_datastore     = "r730-datastore"
#   vsphere_resource_pool = "R730"
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

module "kubernetes_cluster" {
  source = "./modules/kubernetes"

  prod            = var.prod
  tls_secret_name = var.tls_secret_name
  # dockerhub_password             = var.dockerhub_password
  client_certificate_secret_name = var.client_certificate_secret_name
  mailserver_accounts            = var.mailserver_accounts
  mailserver_sasl_passwd         = var.mailserver_sasl_passwd
  mailserver_aliases             = var.mailserver_aliases
  mailserver_opendkim_key        = var.mailserver_opendkim_key
  pihole_web_password            = var.pihole_web_password

  # Webhook tokens
  webhook_handler_secret          = var.webhook_handler_secret
  webhook_handler_fb_verify_token = var.webhook_handler_fb_verify_token
  webhook_handler_fb_page_token   = var.webhook_handler_fb_page_token
  webhook_handler_fb_app_secret   = var.webhook_handler_fb_app_secret
  webhook_handler_git_user        = var.webhook_handler_git_user
  webhook_handler_git_token       = var.webhook_handler_git_token
  webhook_handler_ssh_key         = var.webhook_handler_ssh_key

  wireguard_wg_0_conf   = var.wireguard_wg_0_conf
  wireguard_wg_0_key    = var.wireguard_wg_0_key
  wireguard_firewall_sh = var.wireguard_firewall_sh
  hackmd_db_password    = var.hackmd_db_password

  # using the following hack to dynamically update dns from outside
  bind_db_viktorbarzin_me  = replace(var.bind_db_viktorbarzin_me, "85.130.108.6", "85.130.108.6")
  bind_db_viktorbarzin_lan = var.bind_db_viktorbarzin_lan
  bind_named_conf_options  = var.bind_named_conf_options

  alertmanager_account_password = var.alertmanager_account_password
  alertmanager_slack_api_url    = var.alertmanager_slack_api_url

  # Drone
  drone_github_client_id     = var.drone_github_client_id
  drone_github_client_secret = var.drone_github_client_secret
  drone_rpc_secret           = var.drone_rpc_secret

  # Oauth proxy
  oauth2_proxy_client_id            = var.oauth2_proxy_client_id
  oauth2_proxy_client_secret        = var.oauth2_proxy_client_secret
  oauth2_proxy_authenticated_emails = var.oauth2_proxy_authenticated_emails
  # oauth_client_id     = var.oauth_client_id
  # oauth_client_secret = var.oauth_client_secret
  # depends_on = [module.k8s_master, module.k8s_node1, module.k8s_node2] # wait until master and at least 2 nodes are up

  idrac_username = var.monitoring_idrac_username
  idrac_password = var.monitoring_idrac_password

  url_shortener_geolite_license_key = var.url_shortener_geolite_license_key
  url_shortener_api_key             = var.url_shortener_api_key
  url_shortener_mysql_password      = var.url_shortener_mysql_password

  # dbaas
  dbaas_root_password            = var.dbaas_root_password
  dbaas_postgresql_root_password = var.dbaas_postgresql_root_password
  dbaas_pgadmin_password         = var.dbaas_pgadmin_password

  # home-assistant
  home_assistant_configuration = var.home_assistant_configuration

  # shadowsocks
  shadowsocks_password = var.shadowsocks_password

  # finance app
  finance_app_graphql_api_secret         = var.finance_app_graphql_api_secret
  finance_app_db_connection_string       = var.finance_app_db_connection_string
  finance_app_currency_converter_api_key = var.finance_app_currency_converter_api_key
  finance_app_gocardless_secret_key      = var.finance_app_gocardless_secret_key
  finance_app_gocardless_secret_id       = var.finance_app_gocardless_secret_id

  headscale_config = var.headscale_config
  headscale_acl    = var.headscale_acl

  immich_postgresql_password = var.immich_postgresql_password
  immich_frame_api_key       = var.immich_frame_api_key

  ingress_honeypotapikey              = var.ingress_honeypotapikey
  ingress_crowdsec_api_key            = var.ingress_crowdsec_api_key
  ingress_crowdsec_captcha_secret_key = var.ingress_crowdsec_captcha_secret_key
  ingress_crowdsec_captcha_site_key   = var.ingress_crowdsec_captcha_site_key
  crowdsec_enroll_key                 = var.crowdsec_enroll_key
  crowdsec_db_password                = var.crowdsec_db_password

  vaultwarden_smtp_password = var.vaultwarden_smtp_password

  resume_redis_url    = var.resume_redis_url
  resume_database_url = var.resume_database_url

  frigate_valchedrym_camera_credentials = var.frigate_valchedrym_camera_credentials

  // updating technitium records
  technitium_username = var.technitium_username
  technitium_password = var.technitium_password

  paperless_db_password = var.paperless_db_password

  diun_nfty_token = var.diun_nfty_token
  diun_slack_url  = var.diun_slack_url

  nextcloud_db_password = var.nextcloud_db_password
  homepage_credentials  = var.homepage_credentials

  authentik_secret_key        = var.authentik_secret_key
  authentik_postgres_password = var.authentik_postgres_password

  linkwarden_postgresql_password     = var.linkwarden_postgresql_password
  linkwarden_authentik_client_id     = var.linkwarden_authentik_client_id
  linkwarden_authentik_client_secret = var.linkwarden_authentik_client_secret

  # Cloudflare credentials
  cloudflare_api_key           = var.cloudflare_api_key
  cloudflare_email             = var.cloudflare_email
  cloudflare_account_id        = var.cloudflare_account_id
  cloudflare_zone_id           = var.cloudflare_zone_id
  cloudflare_tunnel_id         = var.cloudflare_tunnel_id
  public_ip                    = var.public_ip
  cloudflare_proxied_names     = var.cloudflare_proxied_names
  cloudflare_non_proxied_names = var.cloudflare_non_proxied_names
  cloudflare_tunnel_token      = var.cloudflare_tunnel_token

  owntracks_credentials = var.owntracks_credentials

  dawarich_database_password = var.dawarich_database_password
  geoapify_api_key           = var.geoapify_api_key

  tandoor_database_password = var.tandoor_database_password
  tandoor_email_password    = var.mailserver_accounts["info@viktorbarzin.me"]

  n8n_postgresql_password = var.n8n_postgresql_password

  realestate_crawler_db_password           = var.realestate_crawler_db_password
  realestate_crawler_notification_settings = var.realestate_crawler_notification_settings

  kured_notify_url = var.kured_notify_url

  onlyoffice_db_password = var.onlyoffice_db_password
  onlyoffice_jwt_token   = var.onlyoffice_jwt_token

  xray_reality_clients     = var.xray_reality_clients
  xray_reality_private_key = var.xray_reality_private_key
  xray_reality_short_ids   = var.xray_reality_short_ids
}


