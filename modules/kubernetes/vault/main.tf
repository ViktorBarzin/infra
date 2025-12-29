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
  namespace       = kubernetes_namespace.vault.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_persistent_volume" "vault_data" {
  metadata {
    name = "vault-data-pv"
  }
  spec {
    capacity = {
      "storage" = "10Gi"
    }
    access_modes = ["ReadWriteOnce"]
    persistent_volume_source {
      nfs {
        server = "10.0.10.15"
        path   = "/mnt/main/vault"
      }
    }
  }
}

resource "helm_release" "vault" {
  namespace        = kubernetes_namespace.vault.metadata[0].name
  create_namespace = true
  name             = "vault"

  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault"

  values = [templatefile("${path.module}/chart_values.tpl", { host = var.host, tls_secret_name = var.tls_secret_name })]

  depends_on = [kubernetes_persistent_volume.vault_data]
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.vault.metadata[0].name
  name            = "vault"
  service_name    = "vault-ui"
  port            = 8200
  tls_secret_name = var.tls_secret_name
  protected       = true
}
