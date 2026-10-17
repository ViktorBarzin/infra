# One Windows app under Wine, shown in the browser through noVNC, asleep when
# idle (ADR-0035). The pod runs the generic public image images/wine-app; the
# app itself is installed on first start into the Wine prefix on the PVC,
# driven by the app's install.sh from var.app_files. README.md has the details.

locals {
  labels = {
    app        = var.name
    "wine-app" = "true" # alert scope: WineAppWakeFailed / WineAppStuckAwake
  }
}

# The Wine prefix: the installed app, its database and its settings. Encrypted
# because apps like iVMS hold residents' personal and biometric data.
resource "kubernetes_persistent_volume_claim" "prefix" {
  wait_until_bound = false
  metadata {
    name      = "${var.name}-prefix"
    namespace = var.namespace
    annotations = {
      "resize.topolvm.io/threshold"     = "10%"
      "resize.topolvm.io/increase"      = "50%"
      "resize.topolvm.io/storage_limit" = var.storage_limit
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted"
    resources {
      requests = {
        storage = var.storage_size
      }
    }
  }
  lifecycle {
    # Autoresizer grows requests.storage up to storage_limit; PVCs can't shrink.
    ignore_changes = [spec[0].resources[0].requests]
  }
}

resource "kubernetes_config_map" "app" {
  metadata {
    name      = "${var.name}-app"
    namespace = var.namespace
  }
  data = var.app_files
}

resource "kubernetes_deployment" "app" {
  # The gate and the idle sleeper own replicas, so the Deployment is usually
  # at 0 and never becomes ready during an apply.
  wait_for_rollout = false
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = local.labels
  }
  spec {
    # Parked by default; the gate scales to 1 on visit.
    replicas = 0
    strategy {
      type = "Recreate" # RWO PVC: the old pod must release it first
    }
    selector {
      match_labels = { app = var.name }
    }
    template {
      metadata {
        labels = local.labels
        annotations = {
          # Roll the pod when the app recipe changes.
          "checksum/app" = sha1(jsonencode(var.app_files))
        }
      }
      spec {
        # SIGTERM -> wineboot --shutdown + wineserver -k in the entrypoint,
        # so the app's database is closed before the kill.
        termination_grace_period_seconds = 60
        security_context {
          run_as_user     = 1000
          run_as_group    = 1000
          fs_group        = 1000
          run_as_non_root = true
        }
        container {
          name  = "app"
          image = "${var.image}:${var.image_tag}"

          port {
            name           = "novnc"
            container_port = 6080
          }

          volume_mount {
            name       = "prefix"
            mount_path = "/data"
          }
          volume_mount {
            name       = "app"
            mount_path = "/app"
            read_only  = true
          }
          volume_mount {
            name       = "shm"
            mount_path = "/dev/shm"
          }

          resources {
            requests = {
              cpu    = var.cpu_request
              memory = var.memory_request
            }
            limits = {
              memory = var.memory_limit
            }
          }

          # Ready only when noVNC answers AND the app's main window exists.
          # The first start installs the app (minutes), so the startup probe
          # allows 30 min.
          startup_probe {
            exec {
              command = ["/usr/local/bin/app-ready"]
            }
            period_seconds    = 20
            timeout_seconds   = 10
            failure_threshold = 90
          }
          readiness_probe {
            exec {
              command = ["/usr/local/bin/app-ready"]
            }
            period_seconds    = 15
            timeout_seconds   = 10
            failure_threshold = 4
          }
        }

        volume {
          name = "prefix"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.prefix.metadata[0].name
          }
        }
        volume {
          name = "app"
          config_map {
            name         = kubernetes_config_map.app.metadata[0].name
            default_mode = "0755"
          }
        }
        volume {
          name = "shm"
          empty_dir {
            medium     = "Memory"
            size_limit = var.shm_size
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      spec[0].replicas,                       # owned by the gate and the idle sleeper
      metadata[0].labels["tier"],             # stamped by Kyverno sync-tier-label-from-namespace
    ]
  }
}

resource "kubernetes_service" "app" {
  metadata {
    name      = var.name
    namespace = var.namespace
    labels    = { app = var.name }
  }
  spec {
    selector = { app = var.name }
    port {
      name        = "http"
      port        = 80
      target_port = 6080
    }
  }
}
