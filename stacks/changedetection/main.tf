variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
resource "kubernetes_namespace" "changedetection" {
  metadata {
    name = "changedetection"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "changedetection-secrets"
      namespace = "changedetection"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "changedetection-secrets"
      }
      dataFrom = [{
        extract = {
          key = "changedetection"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.changedetection]
}

data "kubernetes_secret" "eso_secrets" {
  metadata {
    name      = "changedetection-secrets"
    namespace = kubernetes_namespace.changedetection.metadata[0].name
  }
  depends_on = [kubernetes_manifest.external_secret]
}

locals {
  homepage_credentials = jsondecode(data.kubernetes_secret.eso_secrets.data["homepage_credentials"])
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.changedetection.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_persistent_volume_claim" "data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "changedetection-data-proxmox"
    namespace = kubernetes_namespace.changedetection.metadata[0].name
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

resource "kubernetes_deployment" "changedetection" {
  metadata {
    name      = "changedetection"
    namespace = kubernetes_namespace.changedetection.metadata[0].name
    labels = {
      app  = "changedetection"
      tier = local.tiers.aux
    }
  }
  spec {
    # Disabled: chronic OOM at 64Mi limit, not worth the memory cost to increase
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "changedetection"
      }
    }
    template {
      metadata {
        labels = {
          app = "changedetection"
        }
      }
      spec {
        container {
          name              = "sockpuppetbrowser"
          image             = "dgtlmoon/sockpuppetbrowser:latest"
          image_pull_policy = "IfNotPresent"
          port {
            name           = "ws"
            container_port = 3000
            protocol       = "TCP"
          }
          security_context {
            capabilities {
              add = ["SYS_ADMIN"]
            }
          }
          resources {
            requests = {
              cpu    = "25m"
              memory = "128Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }

        container {
          name  = "changedetection"
          image = "ghcr.io/dgtlmoon/changedetection.io:latest" # latest is latest stable
          env {
            name  = "PLAYWRIGHT_DRIVER_URL"
            value = "ws://localhost:3000"
          }
          env {
            name  = "BASE_URL"
            value = "https://changedetection.viktorbarzin.me"
          }
          env {
            name  = "LOGGER_LEVEL"
            value = "WARNING"
          }
          env {
            name  = "TZ"
            value = "Europe/Sofia"
          }
          volume_mount {
            name       = "data"
            mount_path = "/datastore"
          }
          port {
            name           = "http"
            container_port = 5000
            protocol       = "TCP"
          }
          resources {
            requests = {
              cpu    = "15m"
              memory = "256Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }
        # security_context {
        #   fs_group = "1500"
        # }
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

resource "kubernetes_service" "changedetection" {
  metadata {
    name      = "changedetection"
    namespace = kubernetes_namespace.changedetection.metadata[0].name
    labels = {
      "app" = "changedetection"
    }
  }

  spec {
    selector = {
      app = "changedetection"
    }
    port {
      port        = 80
      target_port = 5000
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.changedetection.metadata[0].name
  name            = "changedetection"
  tls_secret_name = var.tls_secret_name
  protected       = true
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Changedetection"
    "gethomepage.dev/description"  = "Website change monitor"
    "gethomepage.dev/icon"         = "changedetection.png"
    "gethomepage.dev/group"        = "Automation"
    "gethomepage.dev/pod-selector" = ""
    "gethomepage.dev/widget.type"  = "changedetectionio"
    "gethomepage.dev/widget.url"   = "http://changedetection.changedetection.svc.cluster.local"
    "gethomepage.dev/widget.key"   = local.homepage_credentials["changedetection"]["api_key"]
  }
}
