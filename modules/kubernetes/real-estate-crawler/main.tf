variable "tls_secret_name" {}
variable "tier" { type = string }
variable "notification_settings" {
  type = map(string)
  default = {
  }
}
variable "db_password" {}

resource "kubernetes_namespace" "realestate-crawler" {
  metadata {
    name = "realestate-crawler"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.realestate-crawler.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "realestate-crawler-ui" {
  metadata {
    name      = "realestate-crawler-ui"
    namespace = kubernetes_namespace.realestate-crawler.metadata[0].name
    labels = {
      app  = "realestate-crawler-ui"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
    # strategy {
    #   type = "RollingUpdate" # DB is external so we can roll
    # }
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
            container_port = 80
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
      port = 80
    }
  }
}

resource "kubernetes_deployment" "realestate-crawler-api" {
  metadata {
    name      = "realestate-crawler-api"
    namespace = kubernetes_namespace.realestate-crawler.metadata[0].name
    labels = {
      app  = "realestate-crawler-api"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
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
            name  = "DB_CONNECTION_STRING"
            value = "mysql://wrongmove:${var.db_password}@mysql.dbaas.svc.cluster.local:3306/wrongmove"

          }
          # env {
          #   name  = "HTTP_PROXY"
          #   value = "http://tor-proxy.tor-proxy:8118"
          # }
          # env {
          #   name  = "HTTPS_PROXY"
          #   value = "http://tor-proxy.tor-proxy:8118"
          # }
          env {
            name  = "CELERY_BROKER_URL"
            value = "redis://redis.redis.svc.cluster.local:6379/0"
          }
          env {
            name  = "CELERY_RESULT_BACKEND"
            value = "redis://redis.redis.svc.cluster.local:6379/1"
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
            value = var.notification_settings["slack"]
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
          volume_mount {
            name       = "data"
            mount_path = "/app/data"
          }
        }
        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/real-estate-crawler"
            server = "10.0.10.15"
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
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.realestate-crawler.metadata[0].name
  name            = "wrongmove"
  service_name    = "realestate-crawler-ui"
  tls_secret_name = var.tls_secret_name
  rybbit_site_id  = "edee05de453d"
}

module "ingress-api" {
  source          = "../ingress_factory"
  namespace       = kubernetes_namespace.realestate-crawler.metadata[0].name
  name            = "wrongmove-api"
  host            = "wrongmove"
  service_name    = "realestate-crawler-api"
  ingress_path    = ["/api"]
  tls_secret_name = var.tls_secret_name
}


# Celery worker for background task processing
resource "kubernetes_deployment" "realestate-crawler-celery" {
  metadata {
    name      = "realestate-crawler-celery"
    namespace = kubernetes_namespace.realestate-crawler.metadata[0].name
    labels = {
      app  = "realestate-crawler-celery"
      tier = var.tier
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
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
      }
      spec {
        container {
          name              = "celery-worker"
          image             = "viktorbarzin/realestatecrawler:latest"
          image_pull_policy = "Always"
          command           = ["python", "-m", "celery", "-A", "celery_app", "worker", "--loglevel=info"]
          env {
            name  = "ENV"
            value = "prod"
          }
          env {
            name  = "DB_CONNECTION_STRING"
            value = "mysql://wrongmove:${var.db_password}@mysql.dbaas.svc.cluster.local:3306/wrongmove"
          }
          env {
            name  = "CELERY_BROKER_URL"
            value = "redis://redis.redis.svc.cluster.local:6379/0"
          }
          env {
            name  = "CELERY_RESULT_BACKEND"
            value = "redis://redis.redis.svc.cluster.local:6379/1"
          }
          env {
            name  = "SLACK_WEBHOOK_URL"
            value = lookup(var.notification_settings, "slack", "")
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
          nfs {
            path   = "/mnt/main/real-estate-crawler"
            server = "10.0.10.15"
          }
        }
      }
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
      tier = var.tier
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
      }
      spec {
        container {
          name    = "celery-beat"
          image   = "viktorbarzin/realestatecrawler:latest"
          command = ["python", "-m", "celery", "-A", "celery_app", "beat", "--loglevel=info"]
          env {
            name  = "ENV"
            value = "prod"
          }
          env {
            name  = "DB_CONNECTION_STRING"
            value = "mysql://wrongmove:${var.db_password}@mysql.dbaas.svc.cluster.local:3306/wrongmove"
          }
          env {
            name  = "CELERY_BROKER_URL"
            value = "redis://redis.redis.svc.cluster.local:6379/0"
          }
          env {
            name  = "CELERY_RESULT_BACKEND"
            value = "redis://redis.redis.svc.cluster.local:6379/1"
          }
          env {
            name  = "SCRAPE_SCHEDULES"
            value = lookup(var.notification_settings, "scrape_schedules", "")
          }
          volume_mount {
            name       = "data"
            mount_path = "/app/data"
          }
        }
        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/real-estate-crawler"
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}

resource "kubernetes_cron_job_v1" "scrape-rightmove" {
  metadata {
    name      = "scrape-rightmove"
    namespace = kubernetes_namespace.realestate-crawler.metadata[0].name
  }
  spec {
    concurrency_policy            = "Replace"
    failed_jobs_history_limit     = 5
    schedule                      = "0 0 1 * *"
    starting_deadline_seconds     = 10
    successful_jobs_history_limit = 10
    job_template {
      metadata {}
      spec {
        backoff_limit              = 3
        ttl_seconds_after_finished = 10
        template {
          metadata {}
          spec {
            container {
              name  = "scrape-rightmove"
              image = "viktorbarzin/realestatecrawler:latest"
              command = ["/bin/sh", "-c", <<-EOT
                /app/runall.sh # Run the scrape script
              EOT
              ]
              env {
                name  = "DB_CONNECTION_STRING"
                value = "mysql://wrongmove:wrongmove@mysql.dbaas.svc.cluster.local:3306/wrongmove"
              }
              # env {
              #   name  = "HTTP_PROXY"
              #   value = "http://tor-proxy.tor-proxy:8118"
              # }
              # env {
              #   name  = "HTTPS_PROXY"
              #   value = "http://tor-proxy.tor-proxy:8118"
              # }
              volume_mount {
                name       = "data"
                mount_path = "/app/data"
              }
            }
            volume {
              name = "data"
              nfs {
                path   = "/mnt/main/real-estate-crawler"
                server = "10.0.10.15"
              }
            }
          }
        }
      }
    }
  }
}
