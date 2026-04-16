variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "mysql_host" { type = string }

data "vault_kv_secret_v2" "secrets" {
  mount = "secret"
  name  = "url"
}

## Setup
## Need to manually add
## user: shlink
## password: var.url_shortener_mysql_password
## to the mysql tier

variable "domain" {
  default = "url.viktorbarzin.me"
}

resource "kubernetes_namespace" "shlink" {
  metadata {
    name = "url"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
}

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "url-secrets"
      namespace = "url"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "url-secrets"
      }
      dataFrom = [{
        extract = {
          key = "url"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.shlink]
}

# DB credentials from Vault database engine (rotated every 24h)
# NOTE: The kubernetes_secret "mysql_config" still uses plan-time db_password
# from KV. This ExternalSecret provides runtime-refreshed credentials. Once
# the deployment is migrated to use env_from with this secret, the plan-time
# kubernetes_secret can be removed.
resource "kubernetes_manifest" "db_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "url-db-creds"
      namespace = "url"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "url-db-creds"
        template = {
          data = {
            DB_USER     = "shlink"
            DB_PASSWORD = "{{ .password }}"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/mysql-shlink"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.shlink]
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
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
    "DB_PASSWORD" = data.vault_kv_secret_v2.secrets.data["db_password"]
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
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
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
        annotations = {
          "diun.enable"                    = "true"
          "diun.include_tags"              = "^\\d+\\.\\d+\\.\\d+$"
          "dependency.kyverno.io/wait-for" = "mysql.dbaas:3306"
        }
      }
      spec {
        container {
          image = "shlinkio/shlink:4.3.4"
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
            name = "GEOLITE_LICENSE_KEY"
            value_from {
              secret_key_ref {
                name = "url-secrets"
                key  = "geolite_license_key"
              }
            }
          }
          # DB config
          env {
            name  = "DB_DRIVER"
            value = "mysql"
          }
          env {
            name  = "DB_HOST"
            value = var.mysql_host
          }
          # env {
          #   name  = "DB_USER"
          #   value = "shlink"
          # }
          env_from {
            secret_ref {
              name = "url-db-creds"
            }
          }
          # env {
          #   name  = "DB_PASSWORD"
          #   value = data.vault_kv_secret_v2.secrets.data["db_password"]
          # }
          resources {
            limits = {
              memory = "960Mi"
            }
            requests = {
              cpu    = "25m"
              memory = "960Mi"
            }
          }
          port {
            container_port = 8080
          }
          liveness_probe {
            http_get {
              path = "/rest/v3/health"
              port = 8080
            }
            initial_delay_seconds = 15
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 5
          }
          readiness_probe {
            http_get {
              path = "/rest/v3/health"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 3
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
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.shlink.metadata[0].name
  name            = "url"
  service_name    = "shlink"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Shlink"
    "gethomepage.dev/description"  = "URL shortener"
    "gethomepage.dev/icon"         = "shlink.png"
    "gethomepage.dev/group"        = "Productivity"
    "gethomepage.dev/pod-selector" = ""
    "gethomepage.dev/widget.type"  = "shlink"
    "gethomepage.dev/widget.url"   = "http://shlink.shlink.svc.cluster.local:8080"
    "gethomepage.dev/widget.key"   = data.vault_kv_secret_v2.secrets.data["api_key"]
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
      apiKey = data.vault_kv_secret_v2.secrets.data["api_key"]
    }])
  }
}

resource "kubernetes_deployment" "shlink-web" {
  metadata {
    name      = "shlink-web"
    namespace = kubernetes_namespace.shlink.metadata[0].name
    labels = {
      run  = "shlink-web"
      tier = local.tiers.aux
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
              memory = "64Mi"
            }
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
          }
          port {
            container_port = 8080
          }
          liveness_probe {
            http_get {
              path = "/"
              port = 8080
            }
            initial_delay_seconds = 15
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 5
          }
          readiness_probe {
            http_get {
              path = "/"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 3
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
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.shlink.metadata[0].name
  name            = "shlink"
  service_name    = "shlink-web"
  tls_secret_name = var.tls_secret_name
  protected       = true
  extra_annotations = {
    "gethomepage.dev/enabled"      = "false"
    "gethomepage.dev/name"         = "Shlink Web"
    "gethomepage.dev/description"  = "URL shortener web client"
    "gethomepage.dev/icon"         = "shlink.png"
    "gethomepage.dev/group"        = "Productivity"
    "gethomepage.dev/pod-selector" = ""
  }
}
