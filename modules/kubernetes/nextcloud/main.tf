variable "tls_secret_name" {}
variable "db_password" {}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "nextcloud"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_namespace" "nextcloud" {
  metadata {
    name = "nextcloud"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

resource "helm_release" "nextcloud" {
  namespace = "nextcloud"
  name      = "nextcloud"

  repository = "https://nextcloud.github.io/helm/"
  chart      = "nextcloud"
  atomic     = true
  #   version    = "0.7.0"

  values  = [templatefile("${path.module}/chart_values.yaml", { tls_secret_name = var.tls_secret_name, db_password = var.db_password })]
  timeout = 6000
}

# resource "kubernetes_config_map" "config" {
#   metadata {
#     name      = "config"
#     namespace = "nextcloud"

#     annotations = {
#       "reloader.stakater.com/match" = "true"
#     }
#   }

#   data = {
#     "conf.yml" = file("${path.module}/conf.yml")
#   }
# }

# resource "kubernetes_deployment" "nextcloud" {
#   metadata {
#     name      = "nextcloud"
#     namespace = "nextcloud"
#     labels = {
#       app = "nextcloud"
#     }
#     annotations = {
#       "reloader.stakater.com/search" = "true"
#     }
#   }
#   spec {
#     replicas = 1
#     selector {
#       match_labels = {
#         app = "nextcloud"
#       }
#     }
#     template {
#       metadata {
#         annotations = {
#           "diun.enable" = "true"
#         }
#         labels = {
#           app = "nextcloud"
#         }
#       }
#       spec {
#         container {
#           image = "lissy93/nextcloud:latest"
#           name  = "nextcloud"

#           port {
#             container_port = 8080
#           }
#           volume_mount {
#             name       = "config"
#             mount_path = "/app/user-data/"
#           }
#         }
#         volume {
#           name = "config"
#           config_map {
#             name = "config"
#           }
#         }
#       }
#     }
#   }
# }

# resource "kubernetes_service" "nextcloud" {
#   metadata {
#     name      = "nextcloud"
#     namespace = "nextcloud"
#     labels = {
#       app = "nextcloud"
#     }
#   }

#   spec {
#     selector = {
#       app = "nextcloud"
#     }
#     port {
#       name        = "http"
#       port        = 80
#       target_port = 8080
#     }
#   }
# }

resource "kubernetes_persistent_volume" "nextcloud-data-pv" {
  metadata {
    name = "nextcloud-data-pv"
  }
  spec {
    capacity = {
      "storage" = "100Gi"
    }
    access_modes = ["ReadWriteOnce"]
    persistent_volume_source {
      nfs {
        path   = "/mnt/main/nextcloud"
        server = "10.0.10.15"
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "nextcloud-data-pvc" {
  metadata {
    name      = "nextcloud-data-pvc"
    namespace = "nextcloud"
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        "storage" = "100Gi"
      }
    }
    volume_name = "nextcloud-data-pv"
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = "nextcloud"
  name            = "nextcloud"
  tls_secret_name = var.tls_secret_name
  port            = 8080
  extra_annotations = {
    "nginx.ingress.kubernetes.io/client-max-body-size" : "0"
    "nginx.ingress.kubernetes.io/proxy-body-size" : "0",
  }
}
