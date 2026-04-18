variable "tls_secret_name" {}
variable "tier" { type = string }
variable "aiostreams_database_connection_string" { type = string }
variable "nfs_server" { type = string }

resource "kubernetes_namespace" "aiostreams" {
  metadata {
    name = "aiostreams"
    labels = {
      "istio-injection" : "disabled"
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "random_id" "secret_key" {
  byte_length = 32 # 32 bytes × 2 hex chars = 64 hex characters
}

resource "kubernetes_persistent_volume_claim" "data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "aiostreams-data-proxmox"
    namespace = kubernetes_namespace.aiostreams.metadata[0].name
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

resource "kubernetes_deployment" "aiostreams" {
  metadata {
    name      = "aiostreams"
    namespace = kubernetes_namespace.aiostreams.metadata[0].name
    labels = {
      app  = "aiostreams"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "aiostreams"
      }
    }
    template {
      metadata {
        labels = {
          app = "aiostreams"
        }
      }
      spec {
        container {
          image = "viren070/aiostreams:nightly"
          name  = "aiostreams"
          port {
            container_port = 3000
          }
          env {
            name  = "BASE_URL"
            value = "https://aiostreams.viktorbarzin.me"
          }
          env {
            name  = "SECRET_KEY"
            value = random_id.secret_key.hex
          }
          env {
            name  = "DATABASE_URI"
            value = var.aiostreams_database_connection_string
          }
          volume_mount {
            name       = "data"
            mount_path = "/app/data"
          }
          resources {
            requests = {
              cpu    = "25m"
              memory = "768Mi"
            }
            limits = {
              memory = "768Mi"
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
}

resource "kubernetes_service" "aiostreams" {
  metadata {
    name      = "aiostreams"
    namespace = kubernetes_namespace.aiostreams.metadata[0].name
    labels = {
      "app" = "aiostreams"
    }
  }

  spec {
    selector = {
      app = "aiostreams"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 3000
    }
  }
}

module "ingress" {
  source          = "../../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.aiostreams.metadata[0].name
  name            = "aiostreams"
  tls_secret_name = var.tls_secret_name
  #   protected       = true
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "AIOStreams"
    "gethomepage.dev/description"  = "Streaming addon manager"
    "gethomepage.dev/icon"         = "stremio.png"
    "gethomepage.dev/group"        = "Media & Entertainment"
    "gethomepage.dev/pod-selector" = ""
  }
}
