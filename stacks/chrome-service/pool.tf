# Warm pool — ONE always-ready worker so the first concurrent agent never pays a
# cold start (design D6). The broker claims it (patches chrome-pool/session) on
# acquire and returns it to standby (clears the label) on release; burst workers
# above this are broker-created bare Pods (files/broker/worker_pod.json).
#
# SELECTOR GOTCHA: the pod carries app=chrome-worker (so the broker's
# list_workers labelSelector finds warm + bare alike) BUT the Deployment selects
# on chrome-pool/role=warm ONLY — otherwise it would adopt the broker's bare
# burst pods (also app=chrome-worker) and delete them down to replicas=1.
#
# No activeDeadlineSeconds here (that's for the ephemeral bare pods). A stuck or
# wedged warm session is handled by the broker reaper (deletes a warm pod whose
# claim outlives the deadline → the Deployment recreates a fresh one). Container
# spec mirrors files/broker/worker_pod.json — keep them in sync.
resource "kubernetes_deployment" "worker_warm" {
  metadata {
    name      = "chrome-worker-warm"
    namespace = kubernetes_namespace.chrome_service.metadata[0].name
    labels    = merge(local.labels, { app = "chrome-worker", "chrome-pool/role" = "warm" })
    annotations = {
      # Pinned image (matches the master's browser); Keel must not roll it.
      "keel.sh/policy" = "never"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = 0 # stay within the pod quota; brief warm-gap on roll is fine
        max_unavailable = 1
      }
    }
    selector {
      match_labels = { "chrome-pool/role" = "warm" }
    }
    template {
      metadata {
        labels = { app = "chrome-worker", "chrome-pool/role" = "warm" }
      }
      spec {
        image_pull_secrets {
          name = "registry-credentials"
        }
        security_context {
          run_as_user  = 1000
          run_as_group = 1000
          fs_group     = 1000
          seccomp_profile { type = "RuntimeDefault" }
        }
        container {
          name              = "chrome"
          image             = "ghcr.io/viktorbarzin/chrome-service-browser:latest"
          image_pull_policy = "IfNotPresent"
          command           = ["bash", "/scripts/worker_entrypoint.sh"]
          env {
            name  = "DISPLAY"
            value = ":99"
          }
          env {
            name  = "HOME"
            value = "/profile"
          }
          port {
            name           = "cdp"
            container_port = 9222
            protocol       = "TCP"
          }
          readiness_probe {
            tcp_socket { port = 9222 }
            initial_delay_seconds = 3
            period_seconds        = 3
            failure_threshold     = 30
          }
          resources {
            requests = { cpu = "250m", memory = "2Gi" }
            # CPU limit = the deliberate blast-radius exception (design D11): a
            # single-session browser pegging cores is always a bug.
            limits = { cpu = "4", memory = "4Gi" }
          }
          volume_mount {
            name       = "profile"
            mount_path = "/profile"
          }
          volume_mount {
            name       = "dshm"
            mount_path = "/dev/shm"
          }
          volume_mount {
            name       = "scripts"
            mount_path = "/scripts"
            read_only  = true
          }
        }
        volume {
          name = "profile"
          empty_dir {}
        }
        volume {
          name = "dshm"
          empty_dir {
            medium     = "Memory"
            size_limit = "512Mi"
          }
        }
        volume {
          name = "scripts"
          config_map {
            name         = kubernetes_config_map_v1.snapshot_scripts.metadata[0].name
            default_mode = "0555"
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
