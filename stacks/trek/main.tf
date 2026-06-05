# TREK — self-hosted group-trip planner (https://github.com/mauriceboe/TREK).
#
# TRIAL deployment (2026-06-05): solo evaluation behind Authentik forward-auth
# to decide whether an off-the-shelf tool is good enough before building a
# custom app. Upstream image, pinned tag, Terraform-managed (no Keel/CI).
#
# Secrets posture for the trial: TREK auto-generates its ENCRYPTION_KEY onto the
# persistent data PVC and prints a bootstrap admin password to its logs on first
# boot when no ADMIN_* env is set. We rely on that here — no Vault/ESO wiring —
# because the trial data is disposable. IF TREK GRADUATES to a permanent
# deployment: (1) move ENCRYPTION_KEY into Vault (secret/trek) + an ExternalSecret
# so it survives a PVC loss, (2) add an app-level SQLite backup CronJob — the
# host file-backup can't read the LUKS-encrypted PVC, and (3) wire TREK<->Authentik
# OIDC for single sign-on instead of the local admin account.

variable "tls_secret_name" {
  type      = string
  sensitive = true
}

variable "image_tag" {
  type    = string
  default = "3.0.22"
}

resource "kubernetes_namespace" "trek" {
  metadata {
    name = "trek"
    labels = {
      "istio-injection" = "disabled"
      tier              = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label.
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

# SQLite DB + the auto-generated ENCRYPTION_KEY live here → sensitive data, so
# proxmox-lvm-encrypted per the storage rule. Local block also sidesteps the
# SQLite-over-NFS file-locking hazard. Autoresizer annotations + ignore_changes
# on requests are required to coexist with pvc-autoresizer.
resource "kubernetes_persistent_volume_claim" "data" {
  wait_until_bound = false
  metadata {
    name      = "trek-data-encrypted"
    namespace = kubernetes_namespace.trek.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted"
    resources {
      requests = { storage = "2Gi" }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].resources[0].requests]
  }
}

# Trip file attachments (booking confirmations, etc.) → also encrypted local
# block. Separate PVC because TREK mounts uploads at a distinct path.
resource "kubernetes_persistent_volume_claim" "uploads" {
  wait_until_bound = false
  metadata {
    name      = "trek-uploads-encrypted"
    namespace = kubernetes_namespace.trek.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "20Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted"
    resources {
      requests = { storage = "5Gi" }
    }
  }
  lifecycle {
    ignore_changes = [spec[0].resources[0].requests]
  }
}

resource "kubernetes_deployment" "trek" {
  metadata {
    name      = "trek"
    namespace = kubernetes_namespace.trek.metadata[0].name
    labels = {
      app  = "trek"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate" # RWO encrypted volumes
    }
    selector {
      match_labels = {
        app = "trek"
      }
    }
    template {
      metadata {
        labels = {
          app = "trek"
        }
      }
      spec {
        container {
          name              = "trek"
          image             = "mauriceboe/trek:${var.image_tag}"
          image_pull_policy = "IfNotPresent"
          port {
            container_port = 3000
          }
          # No CPU limit (CFS throttling); memory requests=limits. 512Mi is a
          # starting estimate for the Node app — right-size via Goldilocks after
          # the trial.
          resources {
            requests = {
              cpu    = "100m"
              memory = "512Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
          env {
            name  = "APP_URL"
            value = "https://trek.viktorbarzin.me"
          }
          env {
            name  = "ALLOWED_ORIGINS"
            value = "https://trek.viktorbarzin.me"
          }
          env {
            name  = "FORCE_HTTPS"
            value = "true"
          }
          env {
            name  = "TRUST_PROXY"
            value = "1"
          }
          volume_mount {
            name       = "data"
            mount_path = "/app/data"
          }
          volume_mount {
            name       = "uploads"
            mount_path = "/app/uploads"
          }
          # TCP probes — TREK requires login so an HTTP path would 302; a socket
          # check is the robust signal. A generous startup probe protects the
          # first-boot SQLite migration from a premature liveness kill.
          startup_probe {
            tcp_socket {
              port = 3000
            }
            period_seconds    = 5
            failure_threshold = 30
          }
          readiness_probe {
            tcp_socket {
              port = 3000
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
          liveness_probe {
            tcp_socket {
              port = 3000
            }
            period_seconds = 30
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data.metadata[0].name
          }
        }
        volume {
          name = "uploads"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.uploads.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
    ]
  }
}

resource "kubernetes_service" "trek" {
  metadata {
    name      = "trek"
    namespace = kubernetes_namespace.trek.metadata[0].name
    labels = {
      app = "trek"
    }
  }
  spec {
    selector = {
      app = "trek"
    }
    port {
      port        = 80
      target_port = 3000
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.trek.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

# Authentik forward-auth gates the app — for the solo trial it keeps the
# internet out; TREK's own login sits behind it. Proxied via Cloudflare.
module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  auth            = "required"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.trek.metadata[0].name
  name            = "trek"
  service_name    = kubernetes_service.trek.metadata[0].name
  port            = 80
  tls_secret_name = var.tls_secret_name
  homepage_group  = "Productivity"
  extra_annotations = {
    "gethomepage.dev/description" = "Group trip planner (trial)"
    "gethomepage.dev/icon"        = "mdi-bag-suitcase"
  }
}
