variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
resource "kubernetes_namespace" "changedetection" {
  metadata {
    name = "changedetection"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_manifest" "external_secret" {
  field_manager {
    force_conflicts = true
  }
  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "changedetection-secrets"
      namespace = "changedetection"
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "changedetection-secrets"
      }
      dataFrom = [{
        extract = {
          key = "changedetection"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.changedetection]
}

data "kubernetes_secret" "eso_secrets" {
  metadata {
    name      = "changedetection-secrets"
    namespace = kubernetes_namespace.changedetection.metadata[0].name
  }
  depends_on = [kubernetes_manifest.external_secret]
}

locals {
  homepage_credentials = jsondecode(data.kubernetes_secret.eso_secrets.data["homepage_credentials"])
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.changedetection.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# Datastore on NFS. Migrated off proxmox-lvm 2026-06-05 for LUN-cap relief —
# changedetection uses a file-based JSON datastore (no embedded DB), NFS-safe.
# See docs/plans/2026-06-05-block-storage-harden-nfs-design.md
module "nfs_changedetection" {
  source             = "../../modules/kubernetes/nfs_volume"
  name               = "changedetection-data-nfs"
  namespace          = kubernetes_namespace.changedetection.metadata[0].name
  nfs_server         = var.nfs_server
  nfs_path           = "/srv/nfs/changedetection"
  storage            = "8Gi"
  storage_class_name = "nfs-pve"
}

resource "kubernetes_deployment" "changedetection" {
  metadata {
    name      = "changedetection"
    namespace = kubernetes_namespace.changedetection.metadata[0].name
    labels = {
      app  = "changedetection"
      tier = local.tiers.aux
    }
  }
  spec {
    # Disabled: chronic OOM at 64Mi limit, not worth the memory cost to increase
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "changedetection"
      }
    }
    template {
      metadata {
        labels = {
          app = "changedetection"
        }
      }
      spec {
        container {
          name              = "sockpuppetbrowser"
          image             = "dgtlmoon/sockpuppetbrowser:latest"
          image_pull_policy = "IfNotPresent"
          port {
            name           = "ws"
            container_port = 3000
            protocol       = "TCP"
          }
          security_context {
            capabilities {
              add = ["SYS_ADMIN"]
            }
          }
          resources {
            requests = {
              cpu    = "25m"
              memory = "128Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }

        container {
          name  = "changedetection"
          image = "ghcr.io/dgtlmoon/changedetection.io:latest" # latest is latest stable
          env {
            name  = "PLAYWRIGHT_DRIVER_URL"
            value = "ws://localhost:3000"
          }
          env {
            name  = "BASE_URL"
            value = "https://changedetection.viktorbarzin.me"
          }
          env {
            name  = "LOGGER_LEVEL"
            value = "WARNING"
          }
          env {
            name  = "TZ"
            value = "Europe/Sofia"
          }
          volume_mount {
            name       = "data"
            mount_path = "/datastore"
          }
          port {
            name           = "http"
            container_port = 5000
            protocol       = "TCP"
          }
          resources {
            requests = {
              cpu    = "15m"
              memory = "256Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }
        # security_context {
        #   fs_group = "1500"
        # }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = module.nfs_changedetection.claim_name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      # IMAGE_SWAP_DEFERRED: Keel left the two images crossed on 2026-08-26
      # (container sockpuppetbrowser runs ghcr.io/dgtlmoon/changedetection.io:0.55.8,
      # container changedetection runs dgtlmoon/sockpuppetbrowser:0.0.3). Pinning
      # either string here changes the pod, so both images stay ignored until a
      # supervised session puts each image back in its own container
      # (Keel to Renovate cutover, batch B08).
      spec[0].template[0].spec[0].container[0].image, # IMAGE_SWAP_DEFERRED
      spec[0].template[0].spec[0].container[1].image, # IMAGE_SWAP_DEFERRED
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # LEGACY_TEMPLATE_ANNOTATIONS
    ]
  }
}

resource "kubernetes_service" "changedetection" {
  metadata {
    name      = "changedetection"
    namespace = kubernetes_namespace.changedetection.metadata[0].name
    labels = {
      "app" = "changedetection"
    }
  }

  spec {
    selector = {
      app = "changedetection"
    }
    port {
      port        = 80
      target_port = 5000
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.changedetection.metadata[0].name
  name            = "changedetection"
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Changedetection"
    "gethomepage.dev/description"  = "Website change monitor"
    "gethomepage.dev/icon"         = "changedetection.png"
    "gethomepage.dev/group"        = "Automation"
    "gethomepage.dev/pod-selector" = ""
    "gethomepage.dev/widget.type"  = "changedetectionio"
    "gethomepage.dev/widget.url"   = "http://changedetection.changedetection.svc.cluster.local"
    "gethomepage.dev/widget.key"   = local.homepage_credentials["changedetection"]["api_key"]
  }
}
