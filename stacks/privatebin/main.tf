variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }


resource "kubernetes_namespace" "privatebin" {
  metadata {
    name = "privatebin"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.edge
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.privatebin.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_persistent_volume_claim" "data_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "privatebin-data-proxmox"
    namespace = kubernetes_namespace.privatebin.metadata[0].name
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

resource "kubernetes_deployment" "privatebin" {
  metadata {
    name      = "privatebin"
    namespace = kubernetes_namespace.privatebin.metadata[0].name
    labels = {
      app  = "privatebin"
      tier = local.tiers.edge
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "privatebin"
      }
    }
    template {
      metadata {
        labels = {
          app = "privatebin"
        }
      }
      spec {
        container {
          image             = "privatebin/nginx-fpm-alpine"
          name              = "privatebin"
          image_pull_policy = "IfNotPresent"
          port {
            container_port = 8080
          }
          volume_mount {
            name       = "data"
            mount_path = "/srv/data"
            sub_path   = "data"
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

resource "kubernetes_service" "privatebin" {
  metadata {
    name      = "privatebin"
    namespace = kubernetes_namespace.privatebin.metadata[0].name
    labels = {
      "app" = "privatebin"
    }
  }

  spec {
    selector = {
      app = "privatebin"
    }
    port {
      port        = "80"
      target_port = "8080"
    }
  }
}

# Anubis intentionally NOT used here — PrivateBin creates pastes via XHR
# `POST /`, which Anubis's catch-all CHALLENGE rule intercepts and serves
# an HTML challenge page where the JS expects JSON. PrivateBin pastes are
# client-side encrypted, so AI scrapers gain nothing from indexing them;
# the default `anti_ai_scraping` middleware is sufficient protection.

module "ingress" {
  source = "../../modules/kubernetes/ingress_factory"
  # Public pastebin — anyone can create/read pastes. Pastes are client-side
  # encrypted; AI scrapers gain nothing from indexing them. anti_ai_scraping
  # defaults on for auth=none, which is the existing protection.
  auth                           = "none"
  namespace                      = kubernetes_namespace.privatebin.metadata[0].name
  name                           = "privatebin"
  host                           = "pb"
  dns_type                       = "proxied"
  extra_middlewares              = ["traefik-x402@kubernetescrd"]
  tls_secret_name                = var.tls_secret_name
  custom_content_security_policy = "script-src 'self' 'unsafe-inline' 'unsafe-eval' 'wasm-unsafe-eval'"
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "PrivateBin"
    "gethomepage.dev/description"  = "Encrypted pastebin"
    "gethomepage.dev/icon"         = "privatebin.png"
    "gethomepage.dev/group"        = "Development & CI"
    "gethomepage.dev/pod-selector" = ""
  }
}
