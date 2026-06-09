variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
resource "kubernetes_namespace" "immich" {
  metadata {
    name = "freshrss"
    labels = {
      tier               = local.tiers.aux
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "freshrss-secrets"
      namespace = "freshrss"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "freshrss-secrets"
      }
      dataFrom = [{
        extract = {
          key = "freshrss"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.immich]
}

data "kubernetes_secret" "eso_secrets" {
  metadata {
    name      = "freshrss-secrets"
    namespace = kubernetes_namespace.immich.metadata[0].name
  }
  depends_on = [kubernetes_manifest.external_secret]
}

locals {
  homepage_credentials = jsondecode(data.kubernetes_secret.eso_secrets.data["homepage_credentials"])
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = "freshrss"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_persistent_volume_claim" "data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "freshrss-data-proxmox"
    namespace = kubernetes_namespace.immich.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
  lifecycle {
    # The autoresizer expands requests.storage up to storage_limit and
    # PVCs can't shrink. Without this, every TF apply tries to revert
    # to the spec value, K8s rejects the shrink, and the PVC ends up
    # in Terminating-but-in-use limbo.
    ignore_changes = [spec[0].resources[0].requests]
  }
}

# Migrated proxmox-lvm -> NFS (2026-06-04) to free a per-node SCSI-LUN slot
# (node6 LUN-cap relief, beads code-dfjn). FreshRSS extensions are static
# plugin files (no embedded DB; the app DB is external MySQL), so NFS is safe.
module "nfs_extensions" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "freshrss-extensions"
  namespace  = kubernetes_namespace.immich.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/srv/nfs/freshrss/extensions"
  storage    = "1Gi"
}


resource "kubernetes_deployment" "freshrss" {
  metadata {
    name      = "freshrss"
    namespace = "freshrss"
    labels = {
      app                             = "freshrss"
      "kubernetes.io/cluster-service" = "true"
      tier                            = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "freshrss"
      }
    }
    template {
      metadata {
        labels = {
          app                             = "freshrss"
          "kubernetes.io/cluster-service" = "true"
        }
      }
      spec {

        container {
          name  = "freshrss"
          image = "freshrss/freshrss"
          env {
            name  = "CRON_MIN"
            value = "0,30"
          }
          env {
            name  = "BASE_URL"
            value = "https://rss.viktorbarzin.me"
          }
          env {
            name  = "PUBLISHED_PORT"
            value = 80
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/www/FreshRSS/data"
          }
          volume_mount {
            name       = "extensions"
            mount_path = "/var/www/FreshRSS/extensions"
          }
          port {
            name           = "http"
            container_port = 80
            protocol       = "TCP"
          }
          resources {
            requests = {
              cpu    = "15m"
              memory = "256Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data_proxmox.metadata[0].name
          }
        }
        volume {
          name = "extensions"
          persistent_volume_claim {
            claim_name = module.nfs_extensions.claim_name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
      metadata[0].annotations["keel.sh/match-tag"],
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE — Keel manages tag updates
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "freshrss" {
  metadata {
    name      = "freshrss"
    namespace = "freshrss"
    labels = {
      "app" = "freshrss"
    }
  }

  spec {
    selector = {
      app = "freshrss"
    }
    port {
      port        = "80"
      target_port = "80"
    }
  }
}
module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # auth = "app": FreshRSS has built-in user login and exposes Fever +
  # GReader APIs (/api/fever.php, /api/greader.php) used by mobile RSS
  # readers like Reeder/FeedMe. Authentik forward-auth was 302-ing those.
  auth            = "app"
  dns_type        = "proxied"
  namespace       = "freshrss"
  name            = "rss"
  service_name    = "freshrss"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"         = "true"
    "gethomepage.dev/name"            = "FreshRSS"
    "gethomepage.dev/description"     = "RSS feed reader"
    "gethomepage.dev/icon"            = "freshrss.png"
    "gethomepage.dev/group"           = "Productivity"
    "gethomepage.dev/pod-selector"    = ""
    "gethomepage.dev/widget.type"     = "freshrss"
    "gethomepage.dev/widget.url"      = "http://freshrss.freshrss.svc.cluster.local"
    "gethomepage.dev/widget.username" = local.homepage_credentials["freshrss"]["username"]
    "gethomepage.dev/widget.password" = local.homepage_credentials["freshrss"]["password"]
  }
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00
