
variable "tls_secret_name" {}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "dashy"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_namespace" "dashy" {
  metadata {
    name = "dashy"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

resource "kubernetes_config_map" "config" {
  metadata {
    name      = "config"
    namespace = "dashy"

    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }

  data = {
    "conf.yml" = file("${path.module}/conf.yml")
  }
}

resource "kubernetes_deployment" "dashy" {
  metadata {
    name      = "dashy"
    namespace = "dashy"
    labels = {
      app = "dashy"
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "dashy"
      }
    }
    template {
      metadata {
        annotations = {
          # "diun.enable" = "true"
        }
        labels = {
          app = "dashy"
        }
      }
      spec {
        container {
          image = "lissy93/dashy:latest"
          name  = "dashy"

          port {
            container_port = 8080
          }
          volume_mount {
            name       = "config"
            mount_path = "/app/user-data/"
          }
        }
        volume {
          name = "config"
          config_map {
            name = "config"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "dashy" {
  metadata {
    name      = "dashy"
    namespace = "dashy"
    labels = {
      app = "dashy"
    }
  }

  spec {
    selector = {
      app = "dashy"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = "dashy"
  name            = "dashy"
  tls_secret_name = var.tls_secret_name
  protected       = true # hidden as we use homepage now
}

