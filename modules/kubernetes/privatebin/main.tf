variable "tls_secret_name" {}

resource "kubernetes_namespace" "privatebin" {
  metadata {
    name = "privatebin"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "privatebin"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "privatebin" {
  metadata {
    name      = "privatebin"
    namespace = "privatebin"
    labels = {
      app                             = "privatebin"
      "kubernetes.io/cluster-service" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "privatebin"
      }
    }
    template {
      metadata {
        labels = {
          app                             = "privatebin"
          "kubernetes.io/cluster-service" = "true"
        }
      }
      spec {
        container {
          image             = "privatebin/nginx-fpm-alpine"
          name              = "privatebin"
          image_pull_policy = "IfNotPresent"
          port {
            container_port = 8080
          }
          volume_mount {
            name       = "data"
            mount_path = "/srv/data"
            sub_path   = "data"
          }
        }

        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/privatebin"
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "privatebin" {
  metadata {
    name      = "privatebin"
    namespace = "privatebin"
    labels = {
      "app" = "privatebin"
    }
  }

  spec {
    selector = {
      app = "privatebin"
    }
    port {
      port        = "80"
      target_port = "8080"
    }
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = "privatebin"
  name            = "privatebin"
  host            = "pb"
  tls_secret_name = var.tls_secret_name
}
