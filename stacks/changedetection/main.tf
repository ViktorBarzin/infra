variable "tls_secret_name" {
  type = string
  sensitive = true
}
variable "nfs_server" { type = string }
variable "homepage_credentials" {
  type      = map(any)
  sensitive = true
}


resource "kubernetes_namespace" "changedetection" {
  metadata {
    name = "changedetection"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.changedetection.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

module "nfs_data" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "changedetection-data"
  namespace  = kubernetes_namespace.changedetection.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/changedetection"
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
              cpu    = "500m"
              memory = "512Mi"
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
              memory = "64Mi"
            }
            limits = {
              cpu    = "250m"
              memory = "256Mi"
            }
          }
        }
        # security_context {
        #   fs_group = "1500"
        # }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = module.nfs_data.claim_name
          }
        }
      }
    }
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
  namespace       = kubernetes_namespace.changedetection.metadata[0].name
  name            = "changedetection"
  tls_secret_name = var.tls_secret_name
  protected       = true
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Changedetection"
    "gethomepage.dev/description"  = "Website change monitor"
    "gethomepage.dev/icon"         = "changedetection-io.png"
    "gethomepage.dev/group"        = "Automation"
    "gethomepage.dev/pod-selector" = ""
    "gethomepage.dev/widget.type"  = "changedetectionio"
    "gethomepage.dev/widget.url"   = "http://changedetection.changedetection.svc.cluster.local"
    "gethomepage.dev/widget.key"   = var.homepage_credentials["changedetection"]["api_key"]
  }
}
