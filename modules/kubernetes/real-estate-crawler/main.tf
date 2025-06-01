variable "tls_secret_name" {}

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
  namespace       = "realestate-crawler"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_deployment" "realestate-crawler-ui" {
  metadata {
    name      = "realestate-crawler-ui"
    namespace = "realestate-crawler"
    labels = {
      app = "realestate-crawler-ui"
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
          app                             = "realestate-crawler-ui"
          "kubernetes.io/cluster-service" = "true"
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
        }
      }
    }
  }
}

resource "kubernetes_service" "realestate-crawler" {
  metadata {
    name      = "realestate-crawler-ui"
    namespace = "realestate-crawler"
    labels = {
      "app" = "realestate-crawler-ui"
    }
  }

  spec {
    selector = {
      app = "realestate-crawler-ui"
    }
    port {
      port = "80"
    }
  }
}
module "ingress" {
  source          = "../ingress_factory"
  namespace       = "realestate-crawler"
  name            = "wrongmove"
  service_name    = "realestate-crawler-ui"
  tls_secret_name = var.tls_secret_name
}



resource "kubernetes_cron_job_v1" "scrape-rightmove" {
  metadata {
    name      = "scrape-rightmove"
    namespace = "realestate-crawler"
  }
  spec {
    concurrency_policy            = "Replace"
    failed_jobs_history_limit     = 5
    schedule                      = "0 0 * * *"
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
              # command = ["/bin/sh", "-c", <<-EOT
              #   export now=$(date +"%Y_%m_%d_%H_%M")
              #   PGPASSWORD=${var.postgresql_password} pg_dumpall  -h immich-postgresql -U immich > /backup/dump_$now.sql

              #   # Rotate - delete last log file
              #   cd /backup
              #   find . -name "dump_*.sql" -type f -mtime +14 -delete # 14 day retention of backups
              # EOT
              # ]
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
