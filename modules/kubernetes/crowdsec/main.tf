variable "tls_secret_name" {}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "crowdsec"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_namespace" "crowdsec" {
  metadata {
    name = "crowdsec"
  }
}

resource "kubernetes_persistent_volume" "db" {
  metadata {
    name = "crowdsec-db"
  }
  spec {
    capacity = {
      "storage" = "2Gi"
    }
    access_modes = ["ReadWriteOnce"]
    persistent_volume_source {
      nfs {
        path   = "/mnt/main/crowdsec/db"
        server = "10.0.10.15"
      }
    }
    claim_ref {
      name      = "crowdsec-db-pvc"
      namespace = "crowdsec"
    }
  }
}

resource "kubernetes_persistent_volume" "config" {
  metadata {
    name = "crowdsec-config"
  }
  spec {
    capacity = {
      "storage" = "2Gi"
    }
    access_modes = ["ReadWriteOnce"]
    persistent_volume_source {
      nfs {
        path   = "/mnt/main/crowdsec/config"
        server = "10.0.10.15"
      }
    }
    claim_ref {
      name      = "crowdsec-config-pvc"
      namespace = "crowdsec"
    }
  }
}

resource "helm_release" "crowdsec" {
  namespace        = "crowdsec"
  create_namespace = true
  name             = "crowdsec"
  atomic           = true

  repository = "https://crowdsecurity.github.io/helm-charts"
  chart      = "crowdsec"

  values = [templatefile("${path.module}/values.yaml", {})]
}

# resource "kubernetes_ingress_v1" "metabase" {
#   metadata {
#     name      = "metabase"
#     namespace = "crowdsec"
#     annotations = {
#       "kubernetes.io/ingress.class" = "nginx"
#       "nginx.ingress.kubernetes.io/auth-url" : "https://oauth2.viktorbarzin.me/oauth2/auth"
#       "nginx.ingress.kubernetes.io/auth-signin" : "https://oauth2.viktorbarzin.me/oauth2/start?rd=/redirect/$http_host$escaped_request_uri"
#     }
#   }

#   spec {
#     tls {
#       hosts       = ["metabase.viktorbarzin.me"]
#       secret_name = var.tls_secret_name
#     }
#     rule {
#       host = "metabase.viktorbarzin.me"
#       http {
#         path {
#           path = "/"
#           backend {
#             service {
#               name = "crowdsec-service"
#               port {
#                 number = 3000
#               }
#             }
#           }
#         }
#       }
#     }
#   }
# }
