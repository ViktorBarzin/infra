variable "tls_secret_name" {}

resource "kubernetes_namespace" "diun" {
  metadata {
    name = "diun"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "diun"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_service_account" "diun" {
  metadata {
    name      = "diun"
    namespace = "diun"
  }
}

resource "kubernetes_cluster_role" "diun" {
  metadata {
    name = "diun"
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "watch", "list"]
  }
}
resource "kubernetes_cluster_role_binding" "diun" {
  metadata {
    name = "diun"

  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "diun"
  }
  subject {
    kind      = "ServiceAccount"
    name      = "diun"
    namespace = "diun"
  }
}

resource "kubernetes_deployment" "diun" {
  metadata {
    name      = "diun"
    namespace = "diun"
    labels = {
      app = "diun"
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
      "diun.enable"                  = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "diun"
      }
    }
    template {
      metadata {
        labels = {
          app = "diun"
        }
      }
      spec {
        service_account_name = "diun"
        container {
          image = "crazymax/diun:latest"
          name  = "diun"
          args  = ["serve"]
          env {
            name  = "TZ"
            value = "Europe/Sofia"
          }
          env {
            name  = "DIUN_WATCH_WORKERS"
            value = "20"
          }
          env {
            name  = "DIUN_WATCH_SCHEDULE"
            value = "* * * * *"
          }
          env {
            name  = "DIUN_WATCH_JITTER"
            value = "30s"
          }
          env {
            name  = "DIUN_PROVIDERS_KUBERNETES"
            value = "true"
          }

          # volume_mount {
          #   name       = "data"
          #   mount_path = "/data"
          # }
        }
        # volume {
        #   name = "data"
        #   nfs {
        #     path   = "/mnt/main/diun"
        #     server = "10.0.10.15"
        #   }
        # }
      }
    }
  }
}

