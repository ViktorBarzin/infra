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

  # Periodic scrape schedules consumed by celery-beat via SCRAPE_SCHEDULES env var.
  # Schema: config/schedule_config.py:ScheduleConfig. Cron fields are UTC.
  # Daily RENT London 1-2 bed £1900-4000 at 03:00 UTC (~04:00 BST).
  # Weekly BUY London 1-2 bed £400k-1.2M at Sun 04:00 UTC.
  scrape_schedules = jsonencode([
    {
      name           = "london-rent-daily"
      listing_type   = "RENT"
      minute         = "0"
      hour           = "3"
      day_of_week    = "*"
      min_bedrooms   = 1
      max_bedrooms   = 2
      min_price      = 1900
      max_price      = 4000
      district_names = ["London"]
    },
    {
      name           = "london-buy-weekly"
      listing_type   = "BUY"
      minute         = "0"
      hour           = "4"
      day_of_week    = "0"
      min_bedrooms   = 1
      max_bedrooms   = 2
      min_price      = 400000
      max_price      = 1200000
      district_names = ["London"]
    },
  ])
}


resource "kubernetes_namespace" "realestate-crawler" {
  metadata {
    name = "realestate-crawler"
    labels = {
      "istio-injection" : "disabled"
      tier = local.tiers.aux
      "keel.sh/enrolled" = "true"
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
      spec[0].template[0].spec[0].container[0].image,
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
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
          "dependency.kyverno.io/wait-for" = "mysql.dbaas:3306,redis-master.redis:6379"
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
      spec[0].template[0].spec[0].container[0].image,
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
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

# Anubis fronts the UI ingress only; the /api ingress (`module "ingress-api"`)
# stays direct so XHRs from the UI bypass the challenge.
module "anubis" {
  source           = "../../modules/kubernetes/anubis_instance"
  name             = "wrongmove"
  namespace        = kubernetes_namespace.realestate-crawler.metadata[0].name
  target_url       = "http://realestate-crawler-ui.${kubernetes_namespace.realestate-crawler.metadata[0].name}.svc.cluster.local"
  shared_store_url = "redis://redis-master.redis.svc.cluster.local:6379/12"
}

module "ingress" {
  source            = "../../modules/kubernetes/ingress_factory"
  auth              = "none" # Anubis-fronted; PoW challenge gates bots, no Authentik
  dns_type          = "proxied"
  namespace         = kubernetes_namespace.realestate-crawler.metadata[0].name
  name              = "wrongmove"
  service_name      = module.anubis.service_name
  port              = module.anubis.service_port
  extra_middlewares = ["traefik-x402@kubernetescrd"]
  anti_ai_scraping  = false
  tls_secret_name   = var.tls_secret_name
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
  source = "../../modules/kubernetes/ingress_factory"
  # Wrongmove's public UI is Anubis-fronted (auth = "none" on the / path); this
  # /api ingress serves XHRs from that public UI. Forward-auth here would
  # break the UI.
  # auth = "none": XHR endpoint for the Anubis-fronted public UI; forward-auth would break CORS.
  auth            = "none"
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
          "dependency.kyverno.io/wait-for" = "mysql.dbaas:3306,redis-master.redis:6379"
        }
      }
      spec {
        container {
          name              = "celery-worker"
          image             = "viktorbarzin/realestatecrawler:latest"
          image_pull_policy = "Always"
          command           = ["python", "-m", "celery", "-A", "celery_app", "worker", "--loglevel=info", "--pool=threads"]
          # 512Mi OOMed during full London RENT 1-2 bed scrape (~76k existing IDs
          # + 10k fetched into memory at concurrency=8 threads). Bumped to 1Gi.
          resources {
            requests = {
              cpu    = "15m"
              memory = "1Gi"
            }
            limits = {
              memory = "1Gi"
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
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
    ]
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
          "dependency.kyverno.io/wait-for" = "mysql.dbaas:3306,redis-master.redis:6379"
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
            value = local.scrape_schedules
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
      spec[0].template[0].spec[0].dns_config, # KYVERNO_LIFECYCLE_V1
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"], # KYVERNO_LIFECYCLE_V2
    ]
  }
}

# CI retrigger 2026-05-16T13:42:57+00:00 — bulk enrollment apply (pipeline #689 killed)
# CI retrigger v2 2026-05-16T13:46:35+00:00

# CI retrigger v3 2026-05-16T14:06:39Z

# CI retrigger v4 2026-05-16T14:13:59Z

# CI retrigger v5 2026-05-16T23:10:38Z

# CI retrigger v6 2026-05-16T23:18:58Z
