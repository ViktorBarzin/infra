variable "tls_secret_name" {}

resource "kubernetes_namespace" "authelia" {
  metadata {
    name = "authelia"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "authelia"
  tls_secret_name = var.tls_secret_name
}

# resource "helm_release" "authelia" {
#   namespace        = "authelia"
#   create_namespace = true
#   name             = "authelia"
#   atomic           = true

#   repository = "https://charts.authelia.com"
#   chart      = "authelia"
#   version    = "4.38.9"

#   values = [templatefile("${path.module}/values.yaml", {})]
# }

resource "kubernetes_config_map" "configuration" {
  metadata {
    name      = "configuration"
    namespace = "authelia"

    labels = {
      app = "configuration"
    }
    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }

  data = {
    # "configuration.yml" = yamldecode(file("${path.module}/configuration.yml"))
    "configuration.yml"  = file("${path.module}/configuration.yml")
    "users_database.yml" = file("${path.module}/users_database.yml")
  }
}


resource "kubernetes_deployment" "authelia" {
  metadata {
    name      = "authelia"
    namespace = "authelia"
    labels = {
      app = "authelia"
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "authelia"
      }
    }
    template {
      metadata {
        labels = {
          app = "authelia"
        }
      }
      spec {
        container {
          image = "authelia/authelia:4.38"
          name  = "authelia"
          # command = ["tail", "-f", "/etc/passwd"]

          port {
            container_port = 9091
          }
          port {
            container_port = 8080
          }
          volume_mount {
            name = "config"
            # mount_path = "/etc/authelia/configuration.yml"
            mount_path = "/config/configuration.yml"
            sub_path   = "configuration.yml"
          }
          volume_mount {
            name = "users-database"
            # mount_path = "/etc/authelia/users_database.yml"
            mount_path = "/config/users_database.yml"
            sub_path   = "users_database.yml"
          }
        }
        volume {
          name = "config"
          config_map {
            name = "configuration"
          }
        }
        volume {
          name = "users-database"
          config_map {
            name = "configuration"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "authelia" {
  metadata {
    name      = "authelia"
    namespace = "authelia"
    labels = {
      "app" = "authelia"
    }
  }

  spec {
    selector = {
      app = "authelia"
    }
    port {
      name     = "http"
      port     = 80
      protocol = "TCP"
      # target_port = 8080
      target_port = 9091
    }
  }
}

resource "kubernetes_ingress_v1" "authelia" {
  metadata {
    name      = "authelia"
    namespace = "authelia"
    annotations = {
      "kubernetes.io/ingress.class" = "nginx"
      # "nginx.ingress.kubernetes.io/affinity" = "cookie"
      # "nginx.ingress.kubernetes.io/auth-tls-verify-client" = "on"
      # "nginx.ingress.kubernetes.io/auth-tls-secret"        = "default/ca-secret"
      #   "nginx.ingress.kubernetes.io/auth-url" : "https://oauth2.viktorbarzin.me/oauth2/auth"
      #   "nginx.ingress.kubernetes.io/auth-signin" : "https://oauth2.viktorbarzin.me/oauth2/start?rd=/redirect/$http_host$escaped_request_uri"
    }
  }

  spec {
    tls {
      hosts       = ["auth.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "auth.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "authelia"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}
