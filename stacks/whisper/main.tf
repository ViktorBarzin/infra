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
          "gpu" : "true"
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
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
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
          "gpu" : "true"
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
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
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

