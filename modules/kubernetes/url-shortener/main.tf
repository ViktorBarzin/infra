## Setup
## Need to manually add
## user: shlink
## password: var.mysql_password
## to the mysql tier

variable "tls_secret_name" {}
variable "tier" { type = string }
variable "geolite_license_key" {}
variable "api_key" {}
variable "mysql_password" {}
variable "domain" {
  default = "url.viktorbarzin.me"
}

resource "kubernetes_namespace" "shlink" {
  metadata {
    name = "url"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.shlink.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_secret" "mysql_config" {
  metadata {
    name      = "mysql-config"
    namespace = kubernetes_namespace.shlink.metadata[0].name
    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }
  data = {
    "DB_USER"     = "shlink"
    "DB_PASSWORD" = var.mysql_password
  }
}

# this depends on the mysql installation
# resource "kubectl_manifest" "mysql-user" {
#   yaml_body = <<-YAML
#     apiVersion: mysql.presslabs.org/v1alpha1
#     kind: MysqlUser
#     metadata:
#       name: shlink
#      namespace = kubernetes_namespace.shlink.metadata[0].name
#     spec:
#       user: shlink
#       clusterRef:
#         name: mysql-cluster
#        namespace = kubernetes_namespace.shlink.metadata[0].name
#       password:
#         name: mysql-config
#         key: password
#       allowedHosts:
#         - '%'
#   YAML
#   # permissions:
#   #   - schema: db-name-in-mysql
#   #     tables: ["table1", "table2"]
#   #     permissions:
#   #       - SELECT
#   #       - UPDATE
#   #       - CREATE
#   # allowedHosts:
#   #   - localhost
# }

resource "kubernetes_deployment" "shlink" {
  metadata {
    name      = "shlink"
    namespace = kubernetes_namespace.shlink.metadata[0].name
    labels = {
      run  = "shlink"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        run = "shlink"
      }
    }
    template {
      metadata {
        labels = {
          run = "shlink"
        }
      }
      spec {
        container {
          image = "shlinkio/shlink:stable"
          name  = "shlink"
          env {
            name  = "DEFAULT_DOMAIN"
            value = var.domain
          }
          env {
            name  = "SHORT_DOMAIN_SCHEMA"
            value = "https"
          }
          env {
            name  = "GEOLITE_LICENSE_KEY"
            value = var.geolite_license_key
          }
          # DB config
          env {
            name  = "DB_DRIVER"
            value = "mysql"
          }
          env {
            name  = "DB_HOST"
            value = "mysql.dbaas.svc.cluster.local"
          }
          # env {
          #   name  = "DB_USER"
          #   value = "shlink"
          # }
          env_from {
            secret_ref {
              name = "mysql-config"
            }
          }
          # env {
          #   name  = "DB_PASSWORD"
          #   value = var.mysql_password
          # }
          # resources {
          #   limits = {
          #     cpu    = "0.5"
          #     memory = "512Mi"
          #   }
          #   requests = {
          #     cpu    = "250m"
          #     memory = "50Mi"
          #   }
          # }
          port {
            container_port = 8080
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "shlink" {
  metadata {
    name      = "shlink"
    namespace = kubernetes_namespace.shlink.metadata[0].name
    labels = {
      "run" = "shlink"
    }
  }

  spec {
    selector = {
      run = "shlink"
    }
    port {
      name        = "http"
      port        = "80"
      target_port = "8080"
    }
  }
}

module "ingress" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.shlink.metadata[0].name
  name            = "url"
  service_name    = "shlink"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "nginx.ingress.kubernetes.io/configuration-snippet" : <<-EOF
          more_set_headers "Host: $host";
          more_set_headers "X-Real-IP: $remote_addr";
          more_set_headers "X-Forwarded-For: $proxy_add_x_forwarded_for";
          more_set_headers "X-Forwarded-Proto: $scheme";
        EOF
  }
}


# Shlink web client

resource "kubernetes_config_map" "shlink-web" {
  metadata {
    name      = "shlink-web-servers"
    namespace = kubernetes_namespace.shlink.metadata[0].name

    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }

  data = {
    "servers.json" = jsonencode([{
      name   = "Main"
      url    = "https://url.viktorbarzin.me"
      apiKey = var.api_key
    }])
  }
}

resource "kubernetes_deployment" "shlink-web" {
  metadata {
    name      = "shlink-web"
    namespace = kubernetes_namespace.shlink.metadata[0].name
    labels = {
      run  = "shlink-web"
      tier = var.tier
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        run = "shlink-web"
      }
    }
    template {
      metadata {
        labels = {
          run = "shlink-web"
        }
      }
      spec {
        container {
          image = "shlinkio/shlink-web-client"
          name  = "shlink-web"
          volume_mount {
            mount_path = "/usr/share/nginx/html/servers.json"
            sub_path   = "servers.json"
            name       = "config"
          }
          resources {
            limits = {
              cpu    = "0.5"
              memory = "512Mi"
            }
            requests = {
              cpu    = "250m"
              memory = "50Mi"
            }
          }
          port {
            container_port = 8080
          }
        }
        volume {
          name = "config"
          config_map {
            name = "shlink-web-servers"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "shlink-web" {
  metadata {
    name      = "shlink-web"
    namespace = kubernetes_namespace.shlink.metadata[0].name
    labels = {
      "run" = "shlink-web"
    }
  }

  spec {
    selector = {
      run = "shlink-web"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
    }
  }
}

module "ingress-web" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.shlink.metadata[0].name
  name            = "shlink"
  service_name    = "shlink-web"
  tls_secret_name = var.tls_secret_name
  protected       = true
}
