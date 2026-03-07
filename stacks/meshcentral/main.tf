variable "tls_secret_name" {
  type = string
  sensitive = true
}
variable "nfs_server" { type = string }


resource "kubernetes_namespace" "meshcentral" {
  metadata {
    name = "meshcentral"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.meshcentral.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

module "nfs_data" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "meshcentral-data"
  namespace  = kubernetes_namespace.meshcentral.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/meshcentral/meshcentral-data"
}

module "nfs_files" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "meshcentral-files"
  namespace  = kubernetes_namespace.meshcentral.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/meshcentral/meshcentral-files"
}

module "nfs_backups" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "meshcentral-backups"
  namespace  = kubernetes_namespace.meshcentral.metadata[0].name
  nfs_server = var.nfs_server
  nfs_path   = "/mnt/main/meshcentral/meshcentral-backups"
}

resource "kubernetes_deployment" "meshcentral" {
  metadata {
    name      = "meshcentral"
    namespace = kubernetes_namespace.meshcentral.metadata[0].name
    labels = {
      app  = "meshcentral"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
      "meshcentral.enable"           = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "meshcentral"
      }
    }
    template {
      metadata {
        labels = {
          app = "meshcentral"
        }
        annotations = {
          "diun.enable"       = "true"
          "diun.include_tags" = "^\\d+(?:\\.\\d+)?(?:\\.\\d+)?$,latest"
        }
      }
      spec {

        container {
          image = "typhonragewind/meshcentral:latest"
          name  = "meshcentral"
          port {
            name           = "http"
            container_port = 443
          }
          env {
            name  = "TZ"
            value = "Europe/Sofia"
          }
          env {
            name  = "HOSTNAME"
            value = "meshcentral.viktorbarzin.me"
          }
          env {
            name  = "REVERSE_PROXY"
            value = "true"
          }
          env {
            name  = "ALLOW_NEW_ACCOUNTS"
            value = "false"
          }
          env {
            name  = "WEBRTC"
            value = "false"
          }

          volume_mount {
            name       = "data"
            mount_path = "/opt/meshcentral/meshcentral-data"
          }
          volume_mount {
            name       = "files"
            mount_path = "/opt/meshcentral/meshcentral-files"
          }
          resources {
            requests = {
              cpu    = "15m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "250m"
              memory = "512Mi"
            }
          }
          volume_mount {
            name       = "backups"
            mount_path = "/opt/meshcentral/meshcentral-backups"
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = module.nfs_data.claim_name
          }
        }
        volume {
          name = "files"
          persistent_volume_claim {
            claim_name = module.nfs_files.claim_name
          }
        }
        volume {
          name = "backups"
          persistent_volume_claim {
            claim_name = module.nfs_backups.claim_name
          }
        }
      }
    }
  }
}


resource "kubernetes_service" "meshcentral" {
  metadata {
    name      = "meshcentral"
    namespace = kubernetes_namespace.meshcentral.metadata[0].name
    labels = {
      "app" = "meshcentral"
    }
  }

  spec {
    selector = {
      app = "meshcentral"
    }
    port {
      name     = "http"
      port     = 443
      protocol = "TCP"
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.meshcentral.metadata[0].name
  name            = "meshcentral"
  tls_secret_name = var.tls_secret_name
  port            = 443
  protected       = true
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "MeshCentral"
    "gethomepage.dev/description"  = "Remote management"
    "gethomepage.dev/icon"         = "meshcentral.png"
    "gethomepage.dev/group"        = "Infrastructure"
    "gethomepage.dev/pod-selector" = ""
  }
}
