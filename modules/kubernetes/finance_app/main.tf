variable "tls_secret_name" {}
variable "prod_graphql_endpoint" {
  default = "https://finance.viktorbarzin.me/graphql"
}
variable "graphql_api_secret" {}
variable "db_connection_string" {
}
variable "currency_converter_api_key" {}
variable "gocardless_secret_key" {}
variable "gocardless_secret_id" {}


resource "kubernetes_namespace" "finance_app" {
  metadata {
    name = "finance-app"
    # TLS MiTM fails connecting to auth0
    # labels = {
    #   "istio-injection" : "enabled"
    # }
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
          image             = "viktorbarzin/finance-app:latest"
          name              = "finance-app"
          image_pull_policy = "Always"
          # resources {
          #   limits = {
          #     cpu    = "1"
          #     memory = "2Gi"
          #   }
          # }

          env {
            name  = "ENVIRONMENT"
            value = "prod"
          }
          env {
            name  = "DB_CONNECTION_STRING"
            value = var.db_connection_string
          }
          env {
            name  = "GRAPHQL_API_SECRET"
            value = var.graphql_api_secret
          }
          env {
            name  = "ENABLE_SCHEDULER"
            value = 1
          }
          env {
            name  = "DEBUG_METRICS"
            value = 1
          }
          env {
            name  = "ML_MODEL_PATH"
            value = "/data/ml_categorizer.pkl"
          }
          env {
            name  = "LABEL_ENCODER_PATH"
            value = "/data/label_encoder_categorizer.pkl"
          }
          env {
            name  = "VECTORIZER_PATH"
            value = "/data/vectorizer_categorizer.pkl"
          }
          env {
            name  = "CURRENCY_CONVERTER_API_KEY"
            value = var.currency_converter_api_key
          }
          env {
            name  = "GOCARDLESS_SECRET_ID"
            value = var.gocardless_secret_id
          }
          env {
            name  = "GOCARDLESS_SECRET_KEY"
            value = var.gocardless_secret_key
          }
          # volume_mount {
          #   name       = "data"
          #   mount_path = "/data"
          #   # sub_path   = ""
          # }
        }
        # volume {
        #   name = "data"
        #   iscsi {
        #     target_portal = "iscsi.viktorbarzin.me:3260"
        #     fs_type       = "ext4"
        #     iqn           = "iqn.2020-12.lan.viktorbarzin:storage:finance-app"
        #     lun           = 0
        #     read_only     = false
        #   }
        # }
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
          image             = "viktorbarzin/finance-app-frontend:latest"
          name              = "finance-app-frontend"
          image_pull_policy = "Always"
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
      "nginx.ingress.kubernetes.io/proxy-connect-timeout" = "600"
      "nginx.ingress.kubernetes.io/proxy-send-timeout"    = "600"
      "nginx.ingress.kubernetes.io/proxy-read-timeout"    = "600"
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
              name = "finance-app"
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
