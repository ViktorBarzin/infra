variable "db_viktorbarzin_me" {}
variable "db_viktorbarzin_lan" {}
variable "named_conf_options" {}

resource "kubernetes_namespace" "bind" {
  metadata {
    name = "bind"
  }
}

resource "kubernetes_config_map" "bind_configmap" {
  metadata {
    name      = "bind-configmap"
    namespace = "bind"

    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }

  data = {
    "db.viktorbarzin.lan"         = var.db_viktorbarzin_lan
    "db.viktorbarzin.me"          = format("%s%s", var.db_viktorbarzin_me, file("${path.module}/extra/viktorbarzin.me"))
    "db.181.191.213.in-addr.arpa" = var.db_ptr
    "named.conf"                  = var.named_conf
    "named.conf.local"            = var.named_conf_local
    "named.conf.options"          = var.named_conf_options
    "public-named.conf.local"     = var.public_named_conf_local
    "public-named.conf.options"   = var.public_named_conf_options
  }
}

module "bind-local-deployment" {
  source          = "./deployment-factory"
  deployment_name = "bind"
  named_conf_mounts = [
    {
      "mount_path" = "/etc/bind/named.conf.local"
      "sub_path"   = "named.conf.local"
      "name"       = "bindconf"
    },
    {
      mount_path = "/etc/bind/named.conf.options"
      sub_path   = "named.conf.options"
      name       = "bindconf"
    }
  ]
}

module "bind-local-service" {
  source       = "./service-factory"
  service_name = "bind"
  port         = 5354
}

module "bind-public-deployment" {
  source          = "./deployment-factory"
  deployment_name = "bind-public"
  named_conf_mounts = [
    {
      "mount_path" = "/etc/bind/named.conf.local"
      "sub_path"   = "public-named.conf.local"
      "name"       = "bindconf"
    },
    {
      mount_path = "/etc/bind/named.conf.options"
      sub_path   = "public-named.conf.options"
      name       = "bindconf"
    }
  ]
}

module "bind-public-service" {
  source       = "./service-factory"
  service_name = "bind-public"
  port         = 10053
}
