
variable "tls_secret_name" {}
variable "tier" { type = string }
variable "headscale_config" {}
variable "headscale_acl" {}
variable "nfs_server" { type = string }
variable "homepage_token" {
  type      = string
  default   = ""
  sensitive = true
}
variable "ui_cookie_secret" {
  type      = string
  sensitive = true
}
variable "ui_api_key" {
  type      = string
  sensitive = true
}
variable "headscale_derp_map" {
  type = string
}

resource "kubernetes_namespace" "headscale" {
  metadata {
    name = "headscale"
    labels = {
      tier = var.tier
    }
  }
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: goldilocks-vpa-auto-mode ClusterPolicy stamps this label on every namespace
    ignore_changes = [metadata[0].labels["goldilocks.fairwinds.com/vpa-update-mode"]]
  }
}

module "tls_secret" {
  source          = "../../../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.headscale.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

module "nfs_data_host" {
  source     = "../../../../modules/kubernetes/nfs_volume"
  name       = "headscale-data-host"
  namespace  = kubernetes_namespace.headscale.metadata[0].name
  nfs_server = "192.168.1.127"
  nfs_path   = "/srv/nfs/headscale"
}

resource "kubernetes_persistent_volume_claim" "data_encrypted" {
  wait_until_bound = false
  metadata {
    name      = "headscale-data-encrypted"
    namespace = kubernetes_namespace.headscale.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm-encrypted"
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}

resource "kubernetes_deployment" "headscale" {
  metadata {
    name      = "headscale"
    namespace = kubernetes_namespace.headscale.metadata[0].name
    labels = {
      app  = "headscale"
      tier = var.tier
      # scare to try but probably non-http will fail
      # "istio-injection" : "enabled"
    }

    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "headscale"
      }
    }
    template {
      metadata {
        labels = {
          app = "headscale"
        }
        annotations = {
          # "diun.enable"       = "true"
          "diun.enable"       = "false"
          "diun.include_tags" = "^\\d+(?:\\.\\d+)?(?:\\.\\d+)?$"
        }
      }
      spec {
        container {
          image = "headscale/headscale:0.28.0"
          # image   = "headscale/headscale:0.28.0-debug" # -debug is for debug images
          name    = "headscale"
          command = ["headscale", "serve"]

          resources {
            requests = {
              cpu    = "50m"
              memory = "128Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }

          port {
            container_port = 8080
          }
          port {
            container_port = 9090
          }
          port {
            container_port = 41641
          }
          port {
            container_port = 3479
            protocol       = "UDP"
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 15
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 5
          }
          readiness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            initial_delay_seconds = 5
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 3
          }

          volume_mount {
            name       = "config-volume"
            mount_path = "/etc/headscale"
          }

          volume_mount {
            mount_path = "/mnt"
            name       = "nfs-config"
          }
        }
        volume {
          name = "config-volume"
          config_map {
            name = "headscale-config"
            items {
              key  = "config.yaml"
              path = "config.yaml"
            }
            items {
              key  = "acl.yaml"
              path = "acl.yaml"
            }
            items {
              key  = "derp.yaml"
              path = "derp.yaml"
            }
          }
        }

        volume {
          name = "nfs-config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.data_encrypted.metadata[0].name
          }
        }
        # container {
        #   image = "simcu/headscale-ui:0.1.4"
        #   name  = "headscale-ui"
        #   port {
        #     container_port = 80
        #   }
        # }
        container {
          image = "ghcr.io/gurucomputing/headscale-ui@sha256:015f5ba04bcbd5ee03178540a1dbbfc97b6896d7411032e3bf33c2f3e08f8b6f"
          # image = "ghcr.io/tale/headplane:0.3.2"
          name = "headscale-ui"

          resources {
            requests = {
              cpu    = "25m"
              memory = "128Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }

          port {
            container_port = 8081
            # container_port = 3000
          }
          env {
            name  = "HTTP_PORT"
            value = "8081"
          }
          # env {
          #   name  = "HTTPS_PORT"
          #   value = "8082"
          # }
          env {
            name  = "HEADSCALE_URL"
            value = "http://localhost:8080"
          }
          env {
            name  = "COOKIE_SECRET"
            value = var.ui_cookie_secret
          }
          env {
            name  = "ROOT_API_KEY"
            value = var.ui_api_key
          }
        }
        dns_config {
          option {
            name  = "ndots"
            value = "2"
          }
        }
      }
    }
  }
}
resource "kubernetes_service" "headscale" {
  metadata {
    name      = "headscale"
    namespace = kubernetes_namespace.headscale.metadata[0].name
    labels = {
      "app" = "headscale"
    }
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/port"   = "9090"
    }
    # annotations = {
    #   "metallb.universe.tf/allow-shared-ip" : "shared"
    # }
  }

  spec {
    # type                    = "LoadBalancer"
    # external_traffic_policy = "Cluster"
    selector = {
      app = "headscale"

    }
    port {
      name     = "headscale"
      port     = "8080"
      protocol = "TCP"
    }
    port {
      name        = "headscale-ui"
      port        = "80"
      target_port = 8081
      # target_port = 3000
      protocol = "TCP"
    }
    port {
      name     = "metrics"
      port     = "9090"
      protocol = "TCP"
    }
  }
}

module "ingress" {
  source          = "../../../../modules/kubernetes/ingress_factory"
  dns_type        = "non-proxied"
  namespace       = kubernetes_namespace.headscale.metadata[0].name
  name            = "headscale"
  port            = 8080
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Headscale"
    "gethomepage.dev/description"  = "VPN mesh network"
    "gethomepage.dev/icon"         = "headscale.png"
    "gethomepage.dev/group"        = "Identity & Security"
    "gethomepage.dev/pod-selector" = ""
  }
}

# Dedicated IngressRoute for DERP — bypasses CrowdSec, rate limiting, anti-AI,
# and error pages middlewares that interfere with the Upgrade: DERP protocol.
resource "kubernetes_manifest" "derp_ingress_route" {
  manifest = {
    apiVersion = "traefik.io/v1alpha1"
    kind       = "IngressRoute"
    metadata = {
      name      = "headscale-derp"
      namespace = kubernetes_namespace.headscale.metadata[0].name
    }
    spec = {
      entryPoints = ["websecure"]
      routes = [{
        match = "Host(`headscale.viktorbarzin.me`) && PathPrefix(`/derp`)"
        kind  = "Rule"
        services = [{
          name = kubernetes_service.headscale.metadata[0].name
          port = 8080
        }]
        # Minimal middleware — retry + rate-limit. No CrowdSec/anti-AI (DERP is a relay protocol)
        middlewares = [
          {
            name      = "retry"
            namespace = "traefik"
          },
          {
            name      = "rate-limit"
            namespace = "traefik"
          },
        ]
      }]
      tls = {
        secretName = var.tls_secret_name
      }
    }
  }
}

module "ingress-ui" {
  source          = "../../../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.headscale.metadata[0].name
  name            = "headscale-ui"
  host            = "headscale"
  service_name    = "headscale"
  port            = 80
  ingress_path    = ["/web"]
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_service" "headscale-server" {
  metadata {
    name      = "headscale-server"
    namespace = kubernetes_namespace.headscale.metadata[0].name
    labels = {
      "app" = "headscale"
    }
    annotations = {
      "metallb.io/loadBalancerIPs" = "10.0.20.200"
      "metallb.io/allow-shared-ip" = "shared"
    }
  }

  spec {
    type                    = "LoadBalancer"
    external_traffic_policy = "Cluster"
    selector = {
      app = "headscale"

    }
    # port {
    #   name     = "headscale-tcp"
    #   port     = "41641"
    #   protocol = "TCP"
    # }
    port {
      name     = "headscale-udp"
      port     = "41641"
      protocol = "UDP"
    }
    port {
      name     = "stun"
      port     = "3479"
      protocol = "UDP"
    }
  }
}

resource "kubernetes_config_map" "headscale-config" {
  metadata {
    name      = "headscale-config"
    namespace = kubernetes_namespace.headscale.metadata[0].name

    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }

  data = {
    "config.yaml" = var.headscale_config
    "acl.yaml"    = var.headscale_acl
    "derp.yaml"   = var.headscale_derp_map
  }
}

# Backup CronJob — sqlite3 .backup from proxmox-lvm to NFS for cloud sync pickup
# Uses pod_affinity to co-locate with headscale pod (required for RWO PVC access)
resource "kubernetes_cron_job_v1" "headscale_backup" {
  metadata {
    name      = "headscale-backup"
    namespace = kubernetes_namespace.headscale.metadata[0].name
  }
  spec {
    concurrency_policy            = "Replace"
    schedule                      = "0 */6 * * *"
    successful_jobs_history_limit = 1
    failed_jobs_history_limit     = 3
    job_template {
      metadata {}
      spec {
        backoff_limit              = 3
        ttl_seconds_after_finished = 10
        template {
          metadata {}
          spec {
            affinity {
              pod_affinity {
                required_during_scheduling_ignored_during_execution {
                  label_selector {
                    match_labels = {
                      app = "headscale"
                    }
                  }
                  topology_key = "kubernetes.io/hostname"
                }
              }
            }
            container {
              name  = "backup"
              image = "docker.io/library/alpine"
              command = ["/bin/sh", "-c", <<-EOT
                set -euxo pipefail
                apk add --no-cache sqlite
                now=$(date +"%Y_%m_%d_%H_%M")
                mkdir -p /backup
                sqlite3 /data/db.sqlite ".backup /backup/db.sqlite.bak"
                echo "Backup completed at $(date)"
              EOT
              ]
              volume_mount {
                name       = "data"
                mount_path = "/data"
                read_only  = true
              }
              volume_mount {
                name       = "backup"
                mount_path = "/backup"
              }
            }
            volume {
              name = "data"
              persistent_volume_claim {
                claim_name = kubernetes_persistent_volume_claim.data_encrypted.metadata[0].name
              }
            }
            volume {
              name = "backup"
              persistent_volume_claim {
                claim_name = module.nfs_data_host.claim_name
              }
            }
            restart_policy = "OnFailure"
          }
        }
      }
    }
  }
}

# Grafana dashboard
resource "kubernetes_config_map" "grafana_headscale_dashboard" {
  metadata {
    name      = "grafana-headscale-dashboard"
    namespace = "monitoring"
    labels = {
      grafana_dashboard = "1"
    }
    annotations = {
      grafana_folder = "Networking"
    }
  }
  data = {
    "headscale.json" = file("${path.module}/dashboards/headscale.json")
  }
}
