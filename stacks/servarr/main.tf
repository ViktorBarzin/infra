variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "servarr-secrets"
      namespace = "servarr"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "servarr-secrets"
      }
      dataFrom = [{
        extract = {
          key = "servarr"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.servarr]
}

data "kubernetes_secret" "eso_secrets" {
  metadata {
    name      = "servarr-secrets"
    namespace = kubernetes_namespace.servarr.metadata[0].name
  }
  depends_on = [kubernetes_manifest.external_secret]
}

locals {
  homepage_credentials = jsondecode(data.kubernetes_secret.eso_secrets.data["homepage_credentials"])
}


resource "kubernetes_namespace" "servarr" {
  metadata {
    name = "servarr"
    labels = {
      tier = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.servarr.metadata[0].name
  tls_secret_name = var.tls_secret_name
}


# module "readarr" {
#   source          = "./readarr"
#   tls_secret_name = var.tls_secret_name
#   tier = local.tiers.aux
# }

module "prowlarr" {
  source               = "./prowlarr"
  tls_secret_name      = var.tls_secret_name
  tier                 = local.tiers.aux
  nfs_server           = var.nfs_server
  homepage_credentials = local.homepage_credentials
}

module "qbittorrent" {
  source               = "./qbittorrent"
  tls_secret_name      = var.tls_secret_name
  tier                 = local.tiers.aux
  nfs_server           = var.nfs_server
  homepage_credentials = local.homepage_credentials
}

module "flaresolverr" {
  source          = "./flaresolverr"
  tls_secret_name = var.tls_secret_name
  tier            = local.tiers.aux
}

# module "lidarr" {
#   source          = "./lidarr"
#   tls_secret_name = var.tls_secret_name
# tier            = local.tiers.aux
# }

# module "soulseek" {
#   source          = "./soulseek"
#   tls_secret_name = var.tls_secret_name
# tier            = local.tiers.aux
# }

module "listenarr" {
  source          = "./listenarr"
  tls_secret_name = var.tls_secret_name
  tier            = local.tiers.aux
  nfs_server      = var.nfs_server
}

module "aiostreams" {
  source                                = "./aiostreams"
  tls_secret_name                       = var.tls_secret_name
  aiostreams_database_connection_string = data.kubernetes_secret.eso_secrets.data["aiostreams_database_connection_string"]
  tier                                  = local.tiers.aux
  nfs_server                            = var.nfs_server
}


