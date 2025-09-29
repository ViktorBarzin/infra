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
  version    = "8.0.2"

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

resource "kubernetes_deployment" "whiteboard" {
  metadata {
    name      = "whiteboard"
    namespace = "nextcloud"
    labels = {
      app = "whiteboard"
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "whiteboard"
      }
    }
    template {
      metadata {
        labels = {
          app = "whiteboard"
        }
      }
      spec {
        container {
          image = "ghcr.io/nextcloud-releases/whiteboard:release"
          name  = "whiteboard"

          port {
            container_port = 3002
          }
          env {
            name  = "NEXTCLOUD_URL"
            value = "http://nextcloud:8080"
          }
          env {
            name  = "JWT_SECRET_KEY"
            value = var.db_password # anything secret is fine
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "whiteboard" {
  metadata {
    name      = "whiteboard"
    namespace = "nextcloud"
    labels = {
      app = "whiteboard"
    }
  }

  spec {
    selector = {
      app = "whiteboard"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 3002
    }
  }
}

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
    "nginx.ingress.kubernetes.io/limit-rps" : 1000 # Increased to allow webdav syncing
    "nginx.ingress.kubernetes.io/limit-rpm" : 60000
  }
}

module "whiteboard_ingress" {
  source          = "../ingress_factory"
  namespace       = "nextcloud"
  name            = "whiteboard"
  tls_secret_name = var.tls_secret_name
  port            = 80
  extra_annotations = {
    "nginx.ingress.kubernetes.io/client-max-body-size" : "0"
    "nginx.ingress.kubernetes.io/proxy-body-size" : "0",

    # Websockets
    # "nginx.ingress.kubernetes.io/proxy-set-header" : "Upgrade $http_upgrade"
    # "nginx.ingress.kubernetes.io/proxy-set-header" : "Connection $connection_upgrade" # this makes a difference for web!!!

    # Timeouts
    "nginx.ingress.kubernetes.io/proxy-read-timeout" : "6000s",
    "nginx.ingress.kubernetes.io/proxy-send-timeout" : "6000s",
  }
}
