variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
variable "redis_host" { type = string }


resource "kubernetes_namespace" "send" {
  metadata {
    name = "send"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
      "keel.sh/enrolled" = "true"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.send.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# Upload blobs on NFS. Migrated off proxmox-lvm 2026-06-05 for LUN-cap relief —
# Send stores encrypted file blobs on disk (metadata in Redis), no embedded DB,
# NFS-safe. See docs/plans/2026-06-05-block-storage-harden-nfs-design.md
module "nfs_send" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "send-data-nfs"
  namespace  = kubernetes_namespace.send.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/srv/nfs/send"
  storage    = "5Gi"
}

resource "kubernetes_deployment" "send" {
  metadata {
    name      = "send"
    namespace = kubernetes_namespace.send.metadata[0].name
    labels = {
      app  = "send"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "send"
      }
    }
    template {
      metadata {
        labels = {
          app = "send"
        }
      }
      spec {
        container {
          image = "registry.gitlab.com/timvisee/send:latest"
          name  = "send"

          port {
            container_port = 1443
          }
          env {
            name  = "FILE_DIR"
            value = "/uploads"
          }
          env {
            name  = "BASE_URL"
            value = "https://send.viktorbarzin.me"
          }
          env {
            name  = "MAX_FILE_SIZE"
            value = "5368709120"
          }
          env {
            name  = "MAX_DOWNLOADS"
            value = 10 # try to minimize abusive behaviour
          }
          env {
            name  = "MAX_EXPIRE_SECONDS"
            value = 7 * 24 * 3600
          }
          env {
            name  = "REDIS_HOST"
            value = var.redis_host
          }
          liveness_probe {
            http_get {
              path = "/__version__"
              port = 1443
            }
            initial_delay_seconds = 10
            period_seconds        = 30
            failure_threshold     = 3
          }
          volume_mount {
            name       = "data"
            mount_path = "/uploads"
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = module.nfs_send.claim_name
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
resource "kubernetes_service" "send" {
  metadata {
    name      = "send"
    namespace = kubernetes_namespace.send.metadata[0].name
    labels = {
      app = "send"
    }
  }

  spec {
    selector = {
      app = "send"
    }
    port {
      name = "http"
      port = 1443
    }
  }
}
module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # Send is an end-to-end encrypted file-drop — anonymous recipients open a
  # share link to download. Forward-auth would block every share-link user.
  # auth = "none": End-to-end encrypted file-drop — anonymous recipients open share links; forward-auth blocks all share-link access.
  auth            = "none"
  dns_type        = "non-proxied"
  namespace       = kubernetes_namespace.send.metadata[0].name
  name            = "send"
  tls_secret_name = var.tls_secret_name
  port            = 1443
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Send"
    "gethomepage.dev/description"  = "Encrypted file sharing"
    "gethomepage.dev/icon"         = "firefox-send.png"
    "gethomepage.dev/group"        = "Productivity"
    "gethomepage.dev/pod-selector" = ""
  }
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00
