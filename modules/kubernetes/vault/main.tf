variable "tls_secret_name" {}
variable "host" {
  default = "vault.viktorbarzin.me"
}

resource "kubernetes_namespace" "vault" {
  metadata {
    name = "vault"
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "vault"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_persistent_volume" "vault_data" {
  metadata {
    name = "vauld-data-pv"
  }
  spec {
    capacity = {
      "storage" = "10Gi"
    }
    access_modes = ["ReadWriteOnce"]
    persistent_volume_source {
      iscsi {
        target_portal = "iscsi.viktorbarzin.lan:3260"
        iqn           = "iqn.2020-12.lan.viktorbarzin:storage:vault"
        lun           = 0
        fs_type       = "ext4"
      }
    }
  }
}

resource "helm_release" "prometheus" {
  namespace        = "vault"
  create_namespace = true
  name             = "vault"

  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault"

  values = [templatefile("${path.module}/chart_values.tpl", { host = var.host, tls_secret_name = var.tls_secret_name })]
}
