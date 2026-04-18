variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }


resource "kubernetes_namespace" "ntfy" {
  metadata {
    name = "ntfy"
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
  namespace       = kubernetes_namespace.ntfy.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_persistent_volume_claim" "data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "ntfy-data-proxmox"
    namespace = kubernetes_namespace.ntfy.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
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
}

resource "kubernetes_deployment" "ntfy" {
  metadata {
    name      = "ntfy"
    namespace = kubernetes_namespace.ntfy.metadata[0].name
    labels = {
      app  = "ntfy"
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
        app = "ntfy"
      }
    }
    template {
      metadata {
        labels = {
          app = "ntfy"
        }
      }
      spec {
        container {
          image = "binwiederhier/ntfy"
          name  = "ntfy"
          args  = ["serve"]

          port {
            container_port = 80
          }
          liveness_probe {
            http_get {
              path = "/v1/health"
              port = 80
            }
            initial_delay_seconds = 15
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 5
          }
          readiness_probe {
            http_get {
              path = "/v1/health"
              port = 80
            }
            initial_delay_seconds = 5
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 3
          }
          env {
            name  = "NTFY_BASE_URL"
            value = "https://ntfy.viktorbarzin.me"
          }
          env {
            name = "NTFY_UPSTREAM_BASE_URL"
            # value = "https://ntfy.viktorbarzin.me"
            value = "https://ntfy.sh"
          }
          env {
            name  = "NTFY_BEHIND_PROXY"
            value = "true"
          }
          env {
            name  = "NTFY_ENABLE_LOGIN"
            value = "true"
          }
          env {
            name  = "NTFY_AUTH_FILE"
            value = "/var/lib/ntfy/user.db"
          }
          env {
            name  = "NTFY_AUTH_DEFAULT_ACCESS"
            value = "deny-all"
          }
          env {
            name  = "NTFY_ENABLE_METRICS"
            value = "true"
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/ntfy/"
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "128Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data_proxmox.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}

resource "kubernetes_service" "ntfy" {
  metadata {
    name      = "ntfy"
    namespace = kubernetes_namespace.ntfy.metadata[0].name
    labels = {
      "app" = "ntfy"
    }
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/path"   = "/metrics"
      "prometheus.io/port"   = "80"
    }
  }

  spec {
    selector = {
      app = "ntfy"
    }
    port {
      name        = "http"
      target_port = 80
      port        = 80
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.ntfy.metadata[0].name
  name            = "ntfy"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "ntfy"
    "gethomepage.dev/description"  = "Push notifications"
    "gethomepage.dev/icon"         = "ntfy.png"
    "gethomepage.dev/group"        = "Productivity"
    "gethomepage.dev/pod-selector" = ""
  }
}
