variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }


resource "kubernetes_namespace" "whisper" {
  metadata {
    name = "whisper"
    labels = {
      tier = local.tiers.gpu
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
  namespace       = kubernetes_namespace.whisper.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_persistent_volume_claim" "data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "whisper-data-proxmox"
    namespace = kubernetes_namespace.whisper.metadata[0].name
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

resource "kubernetes_deployment" "whisper" {
  metadata {
    name      = "whisper"
    namespace = kubernetes_namespace.whisper.metadata[0].name
    labels = {
      app  = "whisper"
      tier = local.tiers.gpu
    }
  }
  spec {
    replicas = 0 # Scaled down - GPU node memory pressure
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "whisper"
      }
    }
    template {
      metadata {
        labels = {
          app = "whisper"
        }
      }
      spec {
        node_selector = {
          "nvidia.com/gpu.present" : "true"
        }
        toleration {
          key      = "nvidia.com/gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }

        container {
          name  = "whisper"
          image = "rhasspy/wyoming-whisper:latest"
          args  = ["--model", "small-int8", "--language", "en", "--beam-size", "1"]

          port {
            container_port = 10300
            protocol       = "TCP"
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          resources {
            requests = {
              cpu    = "25m"
              memory = "1Gi"
            }
            limits = {
              memory = "1Gi"
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
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
    ]
  }
}

resource "kubernetes_service" "whisper" {
  metadata {
    name      = "whisper"
    namespace = kubernetes_namespace.whisper.metadata[0].name
    labels = {
      app = "whisper"
    }
  }

  spec {
    selector = {
      app = "whisper"
    }
    port {
      name        = "wyoming"
      port        = 10300
      target_port = 10300
      protocol    = "TCP"
    }
  }
}

# TCP passthrough from Traefik to whisper service
resource "kubernetes_manifest" "whisper_tcp_ingressroute" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRouteTCP"
    metadata = {
      name      = "whisper-tcp"
      namespace = "traefik"
    }
    spec = {
      entryPoints = ["whisper-tcp"]
      routes = [{
        match = "HostSNI(`*`)"
        services = [{
          name      = "whisper"
          namespace = "whisper"
          port      = 10300
        }]
      }]
    }
  }
}

# Piper TTS
resource "kubernetes_deployment" "piper" {
  metadata {
    name      = "piper"
    namespace = kubernetes_namespace.whisper.metadata[0].name
    labels = {
      app  = "piper"
      tier = local.tiers.gpu
    }
  }
  spec {
    replicas = 0 # Scaled down - GPU node memory pressure
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "piper"
      }
    }
    template {
      metadata {
        labels = {
          app = "piper"
        }
      }
      spec {
        node_selector = {
          "nvidia.com/gpu.present" : "true"
        }
        toleration {
          key      = "nvidia.com/gpu"
          operator = "Equal"
          value    = "true"
          effect   = "NoSchedule"
        }

        container {
          name  = "piper"
          image = "rhasspy/wyoming-piper:latest"
          args  = ["--voice", "en_US-lessac-medium"]

          port {
            container_port = 10200
            protocol       = "TCP"
          }

          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          resources {
            requests = {
              cpu    = "25m"
              memory = "64Mi"
            }
            limits = {
              memory = "64Mi"
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
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
    ]
  }
}

resource "kubernetes_service" "piper" {
  metadata {
    name      = "piper"
    namespace = kubernetes_namespace.whisper.metadata[0].name
    labels = {
      app = "piper"
    }
  }

  spec {
    selector = {
      app = "piper"
    }
    port {
      name        = "wyoming"
      port        = 10200
      target_port = 10200
      protocol    = "TCP"
    }
  }
}

# TCP passthrough from Traefik to piper service
resource "kubernetes_manifest" "piper_tcp_ingressroute" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRouteTCP"
    metadata = {
      name      = "piper-tcp"
      namespace = "traefik"
    }
    spec = {
      entryPoints = ["piper-tcp"]
      routes = [{
        match = "HostSNI(`*`)"
        services = [{
          name      = "piper"
          namespace = "whisper"
          port      = 10200
        }]
      }]
    }
  }
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00

# CI retrigger v3 2026-05-16T14:06:39Z
