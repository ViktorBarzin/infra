variable "image_tag" {
  type        = string
  default     = "7c01448d"
  description = "priority-pass image tag (applies to both frontend + backend). Use 8-char git SHA in CI; :latest only for local trials."
}

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

locals {
  frontend_image = "docker.io/viktorbarzin/priority-pass-frontend:${var.image_tag}"
  backend_image  = "docker.io/viktorbarzin/priority-pass-backend:${var.image_tag}"
}

resource "kubernetes_namespace" "priority-pass" {
  metadata {
    name = "priority-pass"
    labels = {
      "istio-injection"  = "disabled"
      tier               = local.tiers.aux
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
  namespace       = "priority-pass"
  tls_secret_name = var.tls_secret_name
}

# Uploads on NFS. Migrated off proxmox-lvm-encrypted 2026-06-05 (Phase 1) —
# boarding-pass images, no embedded DB; drops LUKS-at-rest (low-sensitivity, accepted).
# See docs/plans/2026-06-05-block-storage-harden-nfs-design.md
module "nfs_priority_pass" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "priority-pass-uploads-nfs"
  namespace  = kubernetes_namespace.priority-pass.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/priority-pass"
  storage    = "10Gi"
}

resource "kubernetes_deployment" "priority-pass" {
  metadata {
    name      = "priority-pass"
    namespace = "priority-pass"
    labels = {
      run  = "priority-pass"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        run = "priority-pass"
      }
    }
    template {
      metadata {
        labels = {
          run = "priority-pass"
        }
      }
      spec {
        image_pull_secrets {
          name = "registry-credentials"
        }
        volume {
          name = "uploads"
          persistent_volume_claim {
            claim_name = module.nfs_priority_pass.claim_name
          }
        }
        container {
          name  = "frontend"
          image = local.frontend_image
          port {
            container_port = 3000
          }
          env {
            name  = "BACKEND_URL"
            value = "http://127.0.0.1:8000"
          }
          env {
            name  = "ORIGIN"
            value = "https://priority-pass.viktorbarzin.me"
          }
          resources {
            limits = {
              memory = "128Mi"
            }
            requests = {
              cpu    = "10m"
              memory = "128Mi"
            }
          }
        }
        container {
          name  = "backend"
          image = local.backend_image
          port {
            container_port = 8000
          }
          env {
            name  = "UPLOAD_DIR"
            value = "/data/uploads"
          }
          volume_mount {
            name       = "uploads"
            mount_path = "/data/uploads"
          }
          resources {
            limits = {
              memory = "512Mi"
            }
            requests = {
              cpu    = "10m"
              memory = "512Mi"
            }
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
      spec[0].template[0].spec[0].container[1].image,
      metadata[0].annotations["kubernetes.io/change-cause"],
      metadata[0].annotations["deployment.kubernetes.io/revision"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "priority-pass" {
  metadata {
    name      = "priority-pass"
    namespace = "priority-pass"
    labels = {
      run = "priority-pass"
    }
  }
  spec {
    selector = {
      run = "priority-pass"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 3000
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = "priority-pass"
  name            = "priority-pass"
  tls_secret_name = var.tls_secret_name
  auth            = "required"
  max_body_size   = "10m"
  extra_annotations = {
    "gethomepage.dev/icon" = "mdi-airplane"
  }
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00
