variable "tls_secret_name" {}
variable "monzo_client_id" {}
variable "monzo_client_secret" {}
variable "sqlite_db_path" {}
variable "imap_host" {}
variable "imap_user" {}
variable "imap_password" {}
variable "imap_directory" {}
variable "prod_graphql_endpoint" {
  default = "https://finance.viktorbarzin.me/graphql"
}
variable "oauth_google_client_id" {}
variable "oauth_google_client_secret" {}
variable "graphql_api_secret" {}
variable "db_connection_string" {
}


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
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/path"   = "/metrics"
      "prometheus.io/port"   = 5000
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
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/path"   = "/metrics"
          "prometheus.io/port"   = 5000
        }
      }
      spec {
        container {
          image = "viktorbarzin/finance-app"
          name  = "finance-app"

          env {
            name  = "DB_CONNECTION_STRING"
            value = var.db_connection_string
          }
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
          env {
            name  = "OAUTH_GOOGLE_CLIENT_ID"
            value = var.oauth_google_client_id
          }
          env {
            name  = "OAUTH_GOOGLE_CLIENT_SECRET"
            value = var.oauth_google_client_secret
          }
          env {
            name  = "FLASK_DEBUG"
            value = "true"
          }
          env {
            name  = "GRAPHQL_API_SECRET"
            value = var.graphql_api_secret
          }
          env {
            name = "ENABLE_SCHEDULER"
            value = 1
          }
          env {
            name = "DEBUG_METRICS"
            value = 1
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
            target_portal = "iscsi.viktorbarzin.me:3260"
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

resource "kubernetes_deployment" "finance_app_backend_webhook_handler" {
  metadata {
    name      = "finance-app-backend-webhook-handler"
    namespace = "finance-app"
    labels = {
      app = "finance-app-backend-webhook-handler"
    }
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/path"   = "/metrics"
      "prometheus.io/port"   = 5000
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "RollingUpdate"
    }
    selector {
      match_labels = {
        app = "finance-app-backend-webhook-handler"
      }
    }
    template {
      metadata {
        labels = {
          app = "finance-app-backend-webhook-handler"
        }
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/path"   = "/metrics"
          "prometheus.io/port"   = 5000
        }
      }
      spec {
        container {
          image = "viktorbarzin/finance-app-backend-webhook-handler"
          name  = "finance-app-backend-webhook-handler"
          env {
            name  = "GRAPHQL_ENDPOINT"
            value = var.prod_graphql_endpoint
          }
          env {
            name  = "GRAPHQL_API_SECRET"
            value = var.graphql_api_secret
          }
        }
      }
    }
  }
}

resource "kubernetes_deployment" "finance_app_frontend" {
  metadata {
    name      = "finance-app-frontend"
    namespace = "finance-app"
    labels = {
      app = "finance-app-frontend"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "RollingUpdate"
    }
    selector {
      match_labels = {
        app = "finance-app-frontend"
      }
    }
    template {
      metadata {
        labels = {
          app = "finance-app-frontend"
        }
      }
      spec {
        container {
          image = "viktorbarzin/finance-app-frontend"
          name  = "finance-app-frontend"
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
      port = "5000"
    }
  }
}

resource "kubernetes_service" "finance_app_backend_webhook_handler" {
  metadata {
    name      = "finance-app-backend-webhook-handler"
    namespace = "finance-app"
    labels = {
      app = "finance-app-backend-webhook-handler"
    }
  }

  spec {
    selector = {
      app = "finance-app-backend-webhook-handler"
    }
    port {
      name = "http"
      port = "5000"
    }
  }
}
resource "kubernetes_service" "finance_app_frontend" {
  metadata {
    name      = "finance-app-frontend"
    namespace = "finance-app"
    labels = {
      app = "finance-app-frontend"
    }
  }

  spec {
    selector = {
      app = "finance-app-frontend"
    }
    port {
      name = "http"
      port = "3000"
    }
  }
}

resource "kubernetes_ingress_v1" "finance_app" {
  metadata {
    name      = "finance-app"
    namespace = "finance-app"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
      #"nginx.ingress.kubernetes.io/auth-url"= "https://oauth-provider/auth"
      #"nginx.ingress.kubernetes.io/auth-signin"= "https://oauth-provider/sign_in?rd=$request_uri"
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
              name = "finance-app-frontend"
              port {
                number = 3000
              }
            }
          }
        }
      }
    }
    rule {
      host = "finance.viktorbarzin.me"
      http {
        path {
          path = "/graphql"
          backend {
            service {
              name = "finance-app"
              port {
                number = 5000
              }
            }
          }
        }
      }
    }
    rule {
      host = "finance.viktorbarzin.me"
      http {
        path {
          path = "/webhook"
          backend {
            service {
              name = "finance-app-backend-webhook-handler"
              port {
                number = 5000
              }
            }
          }
        }
      }
    }
  }
}
