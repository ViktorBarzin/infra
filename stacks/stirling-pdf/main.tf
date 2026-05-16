variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }


resource "kubernetes_namespace" "stirling-pdf" {
  metadata {
    name = "stirling-pdf"
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
  namespace       = kubernetes_namespace.stirling-pdf.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_persistent_volume_claim" "configs_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "stirling-pdf-configs-proxmox"
    namespace = kubernetes_namespace.stirling-pdf.metadata[0].name
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

resource "kubernetes_deployment" "stirling-pdf" {
  metadata {
    name      = "stirling-pdf"
    namespace = kubernetes_namespace.stirling-pdf.metadata[0].name
    labels = {
      app  = "stirling-pdf"
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
        app = "stirling-pdf"
      }
    }
    template {
      metadata {
        labels = {
          app = "stirling-pdf"
        }
      }
      spec {
        container {
          image = "stirlingtools/stirling-pdf:latest"
          name  = "stirling-pdf"
          resources {
            requests = {
              cpu    = "25m"
              memory = "1536Mi"
            }
            limits = {
              memory = "1536Mi"
            }
          }

          port {
            container_port = 8080
          }
          volume_mount {
            name       = "configs"
            mount_path = "/configs"
          }
        }
        volume {
          name = "configs"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.configs_proxmox.metadata[0].name
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
    ]
  }
}

resource "kubernetes_service" "stirling-pdf" {
  metadata {
    name      = "stirling-pdf"
    namespace = kubernetes_namespace.stirling-pdf.metadata[0].name
    labels = {
      "app" = "stirling-pdf"
    }
  }

  spec {
    selector = {
      app = "stirling-pdf"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  auth            = "required"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.stirling-pdf.metadata[0].name
  name            = "stirling-pdf"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Stirling PDF"
    "gethomepage.dev/description"  = "PDF toolkit"
    "gethomepage.dev/icon"         = "stirling-pdf.png"
    "gethomepage.dev/group"        = "Productivity"
    "gethomepage.dev/pod-selector" = ""
  }
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
