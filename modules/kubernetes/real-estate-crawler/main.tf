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
  protected       = true
}

resource "kubernetes_deployment" "realestate-crawler-api" {
  metadata {
    name      = "realestate-crawler-api"
    namespace = "realestate-crawler"
    labels = {
      app = "realestate-crawler-api"
    }
  }
  spec {
    replicas = 1
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
          name  = "realestate-crawler-ui"
          image = "viktorbarzin/realestatecrawler:latest"
          port {
            name           = "http"
            container_port = 8000
            protocol       = "TCP"
          }
        }
      }
    }
  }
}
resource "kubernetes_service" "realestate-crawler-api" {
  metadata {
    name      = "realestate-crawler-api"
    namespace = "realestate-crawler"
    labels = {
      "app" = "realestate-crawler-api"
    }
  }

  spec {
    selector = {
      app = "realestate-crawler-api"
    }
    port {
      port        = "80"
      target_port = 8000
    }
  }
}
module "ingress-api" {
  source          = "../ingress_factory"
  namespace       = "realestate-crawler"
  name            = "wrongmove-api"
  service_name    = "realestate-crawler-api"
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
                name  = "HTTP_PROXY"
                value = "http://tor-proxy.tor-proxy:8118"
              }
              env {
                name  = "HTTPS_PROXY"
                value = "http://tor-proxy.tor-proxy:8118"
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
  }
}
