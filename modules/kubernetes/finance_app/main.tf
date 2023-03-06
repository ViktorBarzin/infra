variable "tls_secret_name" {}
variable "monzo_client_id" {}
variable "monzo_client_secret" {}
variable "sqlite_db_path" {}
variable "imap_host" {}
variable "imap_user" {}
variable "imap_password" {}
variable "imap_directory" {}


resource "kubernetes_namespace" "finance_app" {
  metadata {
    name = "finance-app"
  }
}


module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "finance-app"
  tls_secret_name = var.tls_secret_name
}

# resource "kubernetes_persistent_volume" "finance_app_pv" {
#   metadata {
#     name = "finance-app-iscsi-pv"
#   }
#   spec {
#     capacity = {
#       "storage" = "5G"
#     }
#     access_modes = ["ReadWriteOnce"]
#     persistent_volume_source {
#       iscsi {
#         target_portal = "iscsi.viktorbarzin.lan:3260"
#         iqn           = "iqn.2020-12.lan.viktorbarzin:storage:finance-app"
#         lun           = 0
#         fs_type       = "ext4"
#       }
#     }
#   }
# }
# resource "kubernetes_persistent_volume_claim" "finance_app_pvc" {
#   metadata {
#     name      = "finance-iscsi-pvc"
#     namespace = "finance-app"
#   }
#   spec {
#     access_modes = ["ReadWriteOnce"]
#     resources {
#       requests = {
#         "storage" = "5Gi"
#       }
#     }
#   }
# }

resource "kubernetes_deployment" "finance_app" {
  metadata {
    name      = "finance-app"
    namespace = "finance-app"
    labels = {
      app = "finance-app"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "finance-app"
      }
    }
    template {
      metadata {
        labels = {
          app = "finance-app"
        }
      }
      spec {
        container {
          image = "viktorbarzin/finance-app"
          name  = "finance-app"

          env {
            name  = "MONZO_CLIENT_ID"
            value = var.monzo_client_id
          }
          env {
            name  = "MONZO_CLIENT_SECRET"
            value = var.monzo_client_secret
          }
          env {
            name  = "SQLITE_DB_PATH"
            value = var.sqlite_db_path
          }
          env {
            name  = "IMAP_HOST"
            value = var.imap_host
          }
          env {
            name  = "IMAP_USER"
            value = var.imap_user
          }
          env {
            name  = "IMAP_PASSWORD"
            value = var.imap_password
          }
          env {
            name  = "IMAP_DIRECTORY"
            value = var.imap_directory
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
            # sub_path   = ""
          }
        }
        volume {
          name = "data"
          iscsi {
            target_portal = "iscsi.viktorbarzin.lan:3260"
            fs_type       = "ext4"
            iqn           = "iqn.2020-12.lan.viktorbarzin:storage:finance-app"
            lun           = 0
            read_only     = false
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "finance_app" {
  metadata {
    name      = "finance-app"
    namespace = "finance-app"
    labels = {
      app = "finance-app"
    }
  }

  spec {
    selector = {
      app = "finance-app"
    }
    port {
      name = "http"
      port = "8000"
    }
  }
}

resource "kubernetes_ingress_v1" "finance_app" {
  metadata {
    name      = "finance-app"
    namespace = "finance-app"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
    }
  }

  spec {
    tls {
      hosts       = ["finance.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "finance.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "finance-app"
              port {
                number = 8000
              }
            }
          }
        }
      }
    }
  }
}
