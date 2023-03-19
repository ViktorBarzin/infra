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
variable "drone_github_client_id" {}
variable "drone_github_client_secret" {}
variable "drone_rpc_secret" {}
# variable "dockerhub_password" {}
# variable "oauth_client_id" {}
# variable "oauth_client_secret" {}
variable "url_shortener_mysql_password" {}
variable "url_shortener_geolite_license_key" {}
variable "url_shortener_api_key" {}
variable "webhook_handler_fb_verify_token" {}
variable "webhook_handler_fb_page_token" {}
variable "webhook_handler_fb_app_secret" {}
variable "webhook_handler_git_user" {}
variable "webhook_handler_git_token" {}
variable "webhook_handler_ssh_key" {}
variable "monitoring_idrac_username" {}
variable "monitoring_idrac_password" {}
variable "alertmanager_slack_api_url" {}
variable "home_assistant_configuration" {}
variable "shadowsocks_password" {}
variable "finance_app_monzo_client_id" {}
variable "finance_app_monzo_client_secret" {}
variable "finance_app_sqlite_db_path" {}
variable "finance_app_imap_host" {}
variable "finance_app_imap_user" {}
variable "finance_app_imap_password" {}
variable "finance_app_imap_directory" {}
variable "finance_app_monzo_registered_accounts_json" {}
variable "finance_app_oauth_google_client_id" {}
variable "finance_app_oauth_google_client_secret" {}

variable "ansible_prefix" {
  default     = "ANSIBLE_VAULT_PASSWORD_FILE=~/.ansible/vault_pass.txt ansible-playbook -i playbook/hosts.yaml playbook/linux.yml -t linux/initial_setup"
  description = "Provisioner command"
}

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

# Main module to init infra from
module "pxe_server" {
  source  = "./modules/create-vm"
  vm_name = "pxe-server"
  network = "dManagementVMs"
  # provisioner_command = "${var.ansible_prefix} -t linux/pxe-server/add-distro"
  provisioner_command = "# no provisioner needed #" # Noop until ubuntu autoinstall is setup

  vsphere_password = var.vsphere_password
  vsphere_user     = var.vsphere_user
  vsphere_server   = var.vsphere_server
  cdrom_path       = "ISO/ubuntu-server-20.04.1.iso"
  vm_disk_size     = 50
  vm_mac_address   = "00:50:56:87:4a:2d"
}

module "k8s_master" {
  source              = "./modules/create-vm"
  vm_name             = "k8s-master"
  vm_mac_address      = "00:50:56:b0:a1:39"
  network             = "dKubernetes"
  provisioner_command = "${var.ansible_prefix} -t linux/k8s/master -e hostname=k8s-master"

  vsphere_password      = var.vsphere_password
  vsphere_user          = var.vsphere_user
  vsphere_server        = var.vsphere_server
  vsphere_datastore     = "r730-datastore"
  vsphere_resource_pool = "R730"

}
module "k8s_node1" {
  source              = "./modules/create-vm"
  vm_name             = "k8s-node1"
  vm_mac_address      = "00:50:56:b0:e0:c9"
  network             = "dKubernetes"
  provisioner_command = "${var.ansible_prefix} -t linux/k8s/node -e hostname=k8s-node1 -e k8s_master='wizard@${module.k8s_master.guest_ip}'"

  vsphere_password      = var.vsphere_password
  vsphere_user          = var.vsphere_user
  vsphere_server        = var.vsphere_server
  vsphere_datastore     = "r730-datastore"
  vsphere_resource_pool = "R730"

}

module "k8s_node2" {
  source              = "./modules/create-vm"
  vm_name             = "k8s-node2"
  vm_mac_address      = "00:50:56:b0:a1:36"
  network             = "dKubernetes"
  provisioner_command = "${var.ansible_prefix} -t linux/k8s/node -e hostname=k8s-node2 -e k8s_master='wizard@${module.k8s_master.guest_ip}'"

  vsphere_password      = var.vsphere_password
  vsphere_user          = var.vsphere_user
  vsphere_server        = var.vsphere_server
  vsphere_datastore     = "r730-datastore"
  vsphere_resource_pool = "R730"
}

module "k8s_node3" {
  source              = "./modules/create-vm"
  vm_name             = "k8s-node3"
  vm_mac_address      = "00:50:56:b0:a1:37"
  network             = "dKubernetes"
  provisioner_command = "${var.ansible_prefix} -t linux/k8s/node -e hostname=k8s-node3 -e k8s_master='wizard@${module.k8s_master.guest_ip}'"

  vsphere_password      = var.vsphere_password
  vsphere_user          = var.vsphere_user
  vsphere_server        = var.vsphere_server
  vsphere_datastore     = "r730-datastore"
  vsphere_resource_pool = "R730"
}

module "k8s_node4" {
  source              = "./modules/create-vm"
  vm_name             = "k8s-node4"
  vm_mac_address      = "00:50:56:b0:a1:38"
  network             = "dKubernetes"
  provisioner_command = "${var.ansible_prefix} -t linux/k8s/node -e hostname=k8s-node4 -e k8s_master='wizard@${module.k8s_master.guest_ip}'"

  vsphere_password      = var.vsphere_password
  vsphere_user          = var.vsphere_user
  vsphere_server        = var.vsphere_server
  vsphere_datastore     = "r730-datastore"
  vsphere_resource_pool = "R730"
}

module "k8s_node5" {
  source              = "./modules/create-vm"
  vm_name             = "k8s-node5"
  vm_mac_address      = "00:50:56:b0:a1:40"
  network             = "dKubernetes"
  provisioner_command = "${var.ansible_prefix} -t linux/k8s/node -e hostname=k8s-node5 -e k8s_master='wizard@${module.k8s_master.guest_ip}'"

  vsphere_password      = var.vsphere_password
  vsphere_user          = var.vsphere_user
  vsphere_server        = var.vsphere_server
  vsphere_datastore     = "r730-datastore"
  vsphere_resource_pool = "R730"

}
module "devvm" {
  source         = "./modules/create-vm"
  vm_name        = "devvm"
  vm_mac_address = "00:50:56:b0:a1:41"
  network        = "dKubernetes"
  # provisioner_command = "${var.ansible_prefix} -t linux/k8s/node -e hostname=k8s-node5 -e k8s_master='wizard@${module.k8s_master.guest_ip}'"

  vsphere_password      = var.vsphere_password
  vsphere_user          = var.vsphere_user
  vsphere_server        = var.vsphere_server
  vsphere_datastore     = "r730-datastore"
  vsphere_resource_pool = "R730"
}

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

  bind_db_viktorbarzin_me  = var.bind_db_viktorbarzin_me
  bind_db_viktorbarzin_lan = var.bind_db_viktorbarzin_lan
  bind_named_conf_options  = var.bind_named_conf_options

  alertmanager_account_password = var.alertmanager_account_password
  alertmanager_slack_api_url    = var.alertmanager_slack_api_url

  # Drone
  drone_github_client_id     = var.drone_github_client_id
  drone_github_client_secret = var.drone_github_client_secret
  drone_rpc_secret           = var.drone_rpc_secret

  # Oauth proxy
  # oauth_client_id     = var.oauth_client_id
  # oauth_client_secret = var.oauth_client_secret
  # depends_on = [module.k8s_master, module.k8s_node1, module.k8s_node2] # wait until master and at least 2 nodes are up

  idrac_username = var.monitoring_idrac_username
  idrac_password = var.monitoring_idrac_password

  url_shortener_geolite_license_key = var.url_shortener_geolite_license_key
  url_shortener_api_key             = var.url_shortener_api_key
  url_shortener_mysql_password      = var.url_shortener_mysql_password

  # dbaas
  dbaas_root_password = var.dbaas_root_password

  # home-assistant
  home_assistant_configuration = var.home_assistant_configuration

  # shadowsocks
  shadowsocks_password = var.shadowsocks_password

  # finance app
  finance_app_monzo_client_id                = var.finance_app_monzo_client_id
  finance_app_monzo_client_secret            = var.finance_app_monzo_client_secret
  finance_app_sqlite_db_path                 = var.finance_app_sqlite_db_path
  finance_app_imap_host                      = var.finance_app_imap_host
  finance_app_imap_user                      = var.finance_app_imap_user
  finance_app_imap_password                  = var.finance_app_imap_password
  finance_app_imap_directory                 = var.finance_app_imap_directory
  finance_app_monzo_registered_accounts_json = var.finance_app_monzo_registered_accounts_json
  finance_app_oauth_google_client_id         = var.finance_app_oauth_google_client_id
  finance_app_oauth_google_client_secret     = var.finance_app_oauth_google_client_secret
}
