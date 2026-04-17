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

module "ingress" {
  source                         = "../../modules/kubernetes/ingress_factory"
  namespace                      = kubernetes_namespace.privatebin.metadata[0].name
  name                           = "privatebin"
  host                           = "pb"
  dns_type                       = "proxied"
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
