variable "tls_secret_name" {}

resource "kubernetes_namespace" "forgejo" {
  metadata {
    name = "forgejo"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "forgejo"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "forgejo" {
  metadata {
    name      = "forgejo"
    namespace = "forgejo"
    labels = {
      app = "forgejo"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "RollingUpdate" # DB is external so we can roll
    }
    selector {
      match_labels = {
        app = "forgejo"
      }
    }
    template {
      metadata {
        labels = {
          app = "forgejo"
        }
      }
      spec {
        container {
          name  = "forgejo"
          image = "codeberg.org/forgejo/forgejo:11"
          env {
            name  = "USER_UID"
            value = 1000
          }
          env {
            name  = "USER_GID"
            value = 1000
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
          port {
            name           = "http"
            container_port = 3000
            protocol       = "TCP"
          }
        }
        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/forgejo"
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "forgejo" {
  metadata {
    name      = "forgejo"
    namespace = "forgejo"
    labels = {
      "app" = "forgejo"
    }
  }

  spec {
    selector = {
      app = "forgejo"
    }
    port {
      port        = 80
      target_port = 3000
    }
  }
}
module "ingress" {
  source          = "../ingress_factory"
  namespace       = "forgejo"
  name            = "forgejo"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "nginx.ingress.kubernetes.io/proxy-body-size" : "20000m"
  }
}
