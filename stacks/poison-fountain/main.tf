variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }


resource "kubernetes_namespace" "poison_fountain" {
  metadata {
    name = "poison-fountain"
    labels = {
      "istio-injection" = "disabled"
      tier              = local.tiers.cluster
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.poison_fountain.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

module "nfs_data_host" {
  source     = "../../modules/kubernetes/nfs_volume"
  name       = "poison-fountain-data-host"
  namespace  = kubernetes_namespace.poison_fountain.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/poison-fountain"
}

# ConfigMap for the Python service code
resource "kubernetes_config_map" "poison_fountain_code" {
  metadata {
    name      = "poison-fountain-code"
    namespace = kubernetes_namespace.poison_fountain.metadata[0].name
  }

  data = {
    "server.py" = file("${path.module}/app/server.py")
  }
}

# ConfigMap for the fetcher script
resource "kubernetes_config_map" "poison_fountain_fetcher" {
  metadata {
    name      = "poison-fountain-fetcher"
    namespace = kubernetes_namespace.poison_fountain.metadata[0].name
  }

  data = {
    "fetch-poison.sh" = file("${path.module}/app/fetch-poison.sh")
  }
}

# Main service deployment
resource "kubernetes_deployment" "poison_fountain" {
  metadata {
    name      = "poison-fountain"
    namespace = kubernetes_namespace.poison_fountain.metadata[0].name
    labels = {
      app  = "poison-fountain"
      tier = local.tiers.cluster
    }
  }

  spec {
    replicas = 0 # Scaled down — clears ExternalAccessDivergence alert
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = 0
        max_surge       = 1
      }
    }
    selector {
      match_labels = {
        app = "poison-fountain"
      }
    }
    template {
      metadata {
        labels = {
          app = "poison-fountain"
        }
      }
      spec {
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "DoNotSchedule"
          label_selector {
            match_labels = {
              app = "poison-fountain"
            }
          }
        }
        container {
          name    = "poison-fountain"
          image   = "python:3.12-slim"
          command = ["python", "/app/server.py"]

          port {
            container_port = 8080
          }

          env {
            name  = "CACHE_DIR"
            value = "/data/cache"
          }
          env {
            name  = "DRIP_BYTES"
            value = "50"
          }
          env {
            name  = "DRIP_DELAY"
            value = "0.5"
          }
          env {
            name  = "POISON_DOMAIN"
            value = "poison.viktorbarzin.me"
          }

          volume_mount {
            name       = "code"
            mount_path = "/app"
            read_only  = true
          }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 30
          }
          readiness_probe {
            http_get {
              path = "/healthz"
              port = 8080
            }
            initial_delay_seconds = 3
            period_seconds        = 10
          }

          resources {
            requests = {
              cpu    = "10m"
              memory = "64Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }
        }

        volume {
          name = "code"
          config_map {
            name = kubernetes_config_map.poison_fountain_code.metadata[0].name
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

# Internal service (for ForwardAuth from Traefik)
resource "kubernetes_service" "poison_fountain" {
  metadata {
    name      = "poison-fountain"
    namespace = kubernetes_namespace.poison_fountain.metadata[0].name
    labels = {
      app = "poison-fountain"
    }
  }

  spec {
    selector = {
      app = "poison-fountain"
    }
    port {
      name        = "http"
      port        = 8080
      target_port = 8080
    }
  }
}

# Public ingress for the poison trap subdomain
# Deliberately NO rate limiting, NO CrowdSec, NO anti-AI (we WANT scrapers here)
module "ingress" {
  source                  = "../../modules/kubernetes/ingress_factory"
  namespace               = kubernetes_namespace.poison_fountain.metadata[0].name
  name                    = "poison-fountain"
  host                    = "poison"
  dns_type                = "non-proxied"
  port                    = 8080
  tls_secret_name         = var.tls_secret_name
  skip_default_rate_limit = true
  exclude_crowdsec        = true
  anti_ai_scraping        = false
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Poison Fountain"
    "gethomepage.dev/description"  = "AI bot trap"
    "gethomepage.dev/icon"         = "mdi-shield-alert"
    "gethomepage.dev/group"        = "Other"
    "gethomepage.dev/pod-selector" = ""
  }
}

# CronJob to fetch and cache poisoned content from Poison Fountain
resource "kubernetes_cron_job_v1" "poison_fetcher" {
  metadata {
    name      = "poison-fountain-fetcher"
    namespace = kubernetes_namespace.poison_fountain.metadata[0].name
  }

  spec {
    schedule                      = "0 */6 * * *"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 1
    concurrency_policy            = "Forbid"

    job_template {
      metadata {
        name = "poison-fountain-fetcher"
      }
      spec {
        template {
          metadata {
            name = "poison-fountain-fetcher"
          }
          spec {
            container {
              name    = "fetcher"
              image   = "curlimages/curl:latest"
              command = ["sh", "/scripts/fetch-poison.sh"]

              env {
                name  = "CACHE_DIR"
                value = "/data/cache"
              }
              env {
                name  = "POISON_URL"
                value = "https://rnsaffn.com/poison2/"
              }
              env {
                name  = "FETCH_COUNT"
                value = "50"
              }

              volume_mount {
                name       = "scripts"
                mount_path = "/scripts"
                read_only  = true
              }
              volume_mount {
                name       = "data"
                mount_path = "/data"
              }
            }

            volume {
              name = "scripts"
              config_map {
                name         = kubernetes_config_map.poison_fountain_fetcher.metadata[0].name
                default_mode = "0755"
              }
            }
            volume {
              name = "data"
              persistent_volume_claim {
                claim_name = module.nfs_data_host.claim_name
              }
            }

            restart_policy = "Never"
          }
        }
      }
    }
  }
}
