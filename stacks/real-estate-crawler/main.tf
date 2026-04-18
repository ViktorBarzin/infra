variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
variable "redis_host" { type = string }
variable "mysql_host" { type = string }

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "real-estate-crawler-secrets"
      namespace = "realestate-crawler"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-kv"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "real-estate-crawler-secrets"
      }
      dataFrom = [{
        extract = {
          key = "real-estate-crawler"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.realestate-crawler]
}

# DB credentials from Vault database engine (rotated automatically)
# Provides DB_CONNECTION_STRING that auto-updates when password rotates
resource "kubernetes_manifest" "db_external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "realestate-crawler-db-creds"
      namespace = "realestate-crawler"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "realestate-crawler-db-creds"
        template = {
          data = {
            DB_CONNECTION_STRING = "mysql://wrongmove:{{ .password }}@${var.mysql_host}:3306/wrongmove"
          }
        }
      }
      data = [{
        secretKey = "password"
        remoteRef = {
          key      = "static-creds/mysql-wrongmove"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.realestate-crawler]
}

data "kubernetes_secret" "eso_secrets" {
  metadata {
    name      = "real-estate-crawler-secrets"
    namespace = kubernetes_namespace.realestate-crawler.metadata[0].name
  }
  depends_on = [kubernetes_manifest.external_secret]
}

locals {
  notification_settings = jsondecode(data.kubernetes_secret.eso_secrets.data["notification_settings"])
}


resource "kubernetes_namespace" "realestate-crawler" {
  metadata {
    name = "realestate-crawler"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.realestate-crawler.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

module "nfs_data_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "real-estate-crawler-data-host"
  namespace  = kubernetes_namespace.realestate-crawler.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/real-estate-crawler"
}

resource "kubernetes_deployment" "realestate-crawler-ui" {
  metadata {
    name      = "realestate-crawler-ui"
    namespace = kubernetes_namespace.realestate-crawler.metadata[0].name
    labels = {
      app  = "realestate-crawler-ui"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 2
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = 0
        max_surge       = 1
      }
    }
    selector {
      match_labels = {
        app = "realestate-crawler-ui"
      }
    }
    template {
      metadata {
        labels = {
          app = "realestate-crawler-ui"
        }
      }
      spec {
        container {
          name  = "realestate-crawler-ui"
          image = "viktorbarzin/immoweb:latest"
          port {
            name           = "http"
            container_port = 8080
            protocol       = "TCP"
          }
          env {
            name  = "ENV"
            value = "prod"
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].container[0].image
    ]
  }
}

resource "kubernetes_service" "realestate-crawler-ui" {
  metadata {
    name      = "realestate-crawler-ui"
    namespace = kubernetes_namespace.realestate-crawler.metadata[0].name
    labels = {
      "app" = "realestate-crawler-ui"
    }
  }

  spec {
    selector = {
      app = "realestate-crawler-ui"
    }
    port {
      port        = 80
      target_port = 8080
    }
  }
}

resource "kubernetes_deployment" "realestate-crawler-api" {
  metadata {
    name      = "realestate-crawler-api"
    namespace = kubernetes_namespace.realestate-crawler.metadata[0].name
    labels = {
      app  = "realestate-crawler-api"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = 0
        max_surge       = 1
      }
    }
    selector {
      match_labels = {
        app = "realestate-crawler-api"
      }
    }
    template {
      metadata {
        labels = {
          app                             = "realestate-crawler-api"
          "kubernetes.io/cluster-service" = "true"
        }
        annotations = {
          "dependency.kyverno.io/wait-for" = "mysql.dbaas:3306,redis.redis:6379"
        }
      }
      spec {
        container {
          name              = "realestate-crawler-api"
          image             = "viktorbarzin/realestatecrawler:latest"
          image_pull_policy = "Always"
          env {
            name  = "ENV"
            value = "prod"
          }
          env {
            name = "DB_CONNECTION_STRING"
            value_from {
              secret_key_ref {
                name = "realestate-crawler-db-creds"
                key  = "DB_CONNECTION_STRING"
              }
            }
          }
          env {
            name  = "CELERY_BROKER_URL"
            value = "redis://${var.redis_host}:6379/0"
          }
          env {
            name  = "CELERY_RESULT_BACKEND"
            value = "redis://${var.redis_host}:6379/1"
          }

          env {
            name  = "UVICORN_LOG_LEVEL"
            value = "debug"
          }
          env {
            name  = "OSRM_FOOT_URL"
            value = "http://osrm-foot.osm-routing.svc.cluster.local:5000"
          }
          env {
            name  = "OSRM_BICYCLE_URL"
            value = "http://osrm-bicycle.osm-routing.svc.cluster.local:5000"
          }
          env {
            name  = "OTP_URL"
            value = "http://otp.osm-routing.svc.cluster.local:8080"
          }
          env {
            name  = "SLACK_WEBHOOK_URL"
            value = local.notification_settings["slack"]["webhook_url"]
          }
          env {
            name  = "WEBAUTHN_RP_ID"
            value = "wrongmove.viktorbarzin.me"
          }
          env {
            name  = "WEBAUTHN_ORIGIN"
            value = "https://wrongmove.viktorbarzin.me"
          }
          port {
            name           = "http"
            container_port = 5001
            protocol       = "TCP"
          }
          resources {
            requests = {
              cpu    = "15m"
              memory = "256Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
          volume_mount {
            name       = "data"
            mount_path = "/app/data"
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = module.nfs_data_host.claim_name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].container[0].image
    ]
  }
}
resource "kubernetes_service" "realestate-crawler-api" {
  metadata {
    name      = "realestate-crawler-api"
    namespace = kubernetes_namespace.realestate-crawler.metadata[0].name
    labels = {
      "app" = "realestate-crawler-api"
    }
  }

  spec {
    selector = {
      app = "realestate-crawler-api"
    }
    port {
      port        = 80
      target_port = 5001
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.realestate-crawler.metadata[0].name
  name            = "wrongmove"
  service_name    = "realestate-crawler-ui"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Wrongmove"
    "gethomepage.dev/description"  = "Property search"
    "gethomepage.dev/icon"         = "home-assistant.png"
    "gethomepage.dev/group"        = "Other"
    "gethomepage.dev/pod-selector" = ""
  }
}

module "ingress-api" {
  source          = "../../modules/kubernetes/ingress_factory"
  dns_type        = "proxied"
  namespace       = kubernetes_namespace.realestate-crawler.metadata[0].name
  name            = "wrongmove-api"
  host            = "wrongmove"
  service_name    = "realestate-crawler-api"
  ingress_path    = ["/api"]
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled" = "false"
  }
}


# Celery worker for background task processing
resource "kubernetes_deployment" "realestate-crawler-celery" {
  metadata {
    name      = "realestate-crawler-celery"
    namespace = kubernetes_namespace.realestate-crawler.metadata[0].name
    labels = {
      app  = "realestate-crawler-celery"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = 0
        max_surge       = 1
      }
    }
    selector {
      match_labels = {
        app = "realestate-crawler-celery"
      }
    }
    template {
      metadata {
        labels = {
          app = "realestate-crawler-celery"
        }
        annotations = {
          "dependency.kyverno.io/wait-for" = "mysql.dbaas:3306,redis.redis:6379"
        }
      }
      spec {
        container {
          name              = "celery-worker"
          image             = "viktorbarzin/realestatecrawler:latest"
          image_pull_policy = "Always"
          command           = ["python", "-m", "celery", "-A", "celery_app", "worker", "--loglevel=info", "--pool=threads"]
          resources {
            requests = {
              cpu    = "15m"
              memory = "512Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
          port {
            name           = "metrics"
            container_port = 9090
            protocol       = "TCP"
          }
          env {
            name  = "ENV"
            value = "prod"
          }
          env {
            name = "DB_CONNECTION_STRING"
            value_from {
              secret_key_ref {
                name = "realestate-crawler-db-creds"
                key  = "DB_CONNECTION_STRING"
              }
            }
          }
          env {
            name  = "CELERY_BROKER_URL"
            value = "redis://${var.redis_host}:6379/0"
          }
          env {
            name  = "CELERY_RESULT_BACKEND"
            value = "redis://${var.redis_host}:6379/1"
          }
          env {
            name  = "SLACK_WEBHOOK_URL"
            value = try(local.notification_settings["slack"]["webhook_url"], "")
          }
          env {
            name  = "OSRM_FOOT_URL"
            value = "http://osrm-foot.osm-routing.svc.cluster.local:5000"
          }
          env {
            name  = "OSRM_BICYCLE_URL"
            value = "http://osrm-bicycle.osm-routing.svc.cluster.local:5000"
          }
          env {
            name  = "OTP_URL"
            value = "http://otp.osm-routing.svc.cluster.local:8080"
          }
          volume_mount {
            name       = "data"
            mount_path = "/app/data"
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = module.nfs_data_host.claim_name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "realestate-crawler-celery-metrics" {
  metadata {
    name      = "realestate-crawler-celery-metrics"
    namespace = kubernetes_namespace.realestate-crawler.metadata[0].name
    labels = {
      "app" = "realestate-crawler-celery"
    }
  }

  spec {
    selector = {
      app = "realestate-crawler-celery"
    }
    port {
      port        = 9090
      target_port = 9090
    }
  }
}

# Celery beat for scheduled task management
resource "kubernetes_deployment" "realestate-crawler-celery-beat" {
  metadata {
    name      = "realestate-crawler-celery-beat"
    namespace = kubernetes_namespace.realestate-crawler.metadata[0].name
    labels = {
      app  = "realestate-crawler-celery-beat"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate" # Only one beat instance should run at a time
    }
    selector {
      match_labels = {
        app = "realestate-crawler-celery-beat"
      }
    }
    template {
      metadata {
        labels = {
          app = "realestate-crawler-celery-beat"
        }
        annotations = {
          "dependency.kyverno.io/wait-for" = "mysql.dbaas:3306,redis.redis:6379"
        }
      }
      spec {
        container {
          name    = "celery-beat"
          image   = "viktorbarzin/realestatecrawler:latest"
          command = ["python", "-m", "celery", "-A", "celery_app", "beat", "--loglevel=info"]
          resources {
            requests = {
              cpu    = "10m"
              memory = "256Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }
          env {
            name  = "ENV"
            value = "prod"
          }
          env {
            name = "DB_CONNECTION_STRING"
            value_from {
              secret_key_ref {
                name = "realestate-crawler-db-creds"
                key  = "DB_CONNECTION_STRING"
              }
            }
          }
          env {
            name  = "CELERY_BROKER_URL"
            value = "redis://${var.redis_host}:6379/0"
          }
          env {
            name  = "CELERY_RESULT_BACKEND"
            value = "redis://${var.redis_host}:6379/1"
          }
          env {
            name  = "SCRAPE_SCHEDULES"
            value = try(tostring(local.notification_settings["scrape_schedules"]), "")
          }
          volume_mount {
            name       = "data"
            mount_path = "/app/data"
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = module.nfs_data_host.claim_name
          }
        }
      }
    }
  }
}
