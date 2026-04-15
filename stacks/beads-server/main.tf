variable "tls_secret_name" {
  type      = string
  sensitive = true
}

resource "kubernetes_namespace" "beads" {
  metadata {
    name = "beads-server"
    labels = {
      tier = local.tiers.aux
    }
  }
}

resource "kubernetes_persistent_volume_claim" "dolt_data" {
  wait_until_bound = false
  metadata {
    name      = "dolt-data"
    namespace = kubernetes_namespace.beads.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "10Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = { storage = "2Gi" }
    }
  }
}

resource "kubernetes_config_map" "dolt_init" {
  metadata {
    name      = "dolt-init"
    namespace = kubernetes_namespace.beads.metadata[0].name
  }
  data = {
    "01-create-beads-user.sql" = <<-EOT
      CREATE USER IF NOT EXISTS 'beads'@'%' IDENTIFIED BY '';
      GRANT ALL PRIVILEGES ON *.* TO 'beads'@'%' WITH GRANT OPTION;
    EOT
  }
}

resource "kubernetes_deployment" "dolt" {
  metadata {
    name      = "dolt"
    namespace = kubernetes_namespace.beads.metadata[0].name
    labels = {
      app  = "dolt"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "dolt"
      }
    }
    template {
      metadata {
        labels = {
          app = "dolt"
        }
      }
      spec {
        container {
          name  = "dolt"
          image = "dolthub/dolt-sql-server:latest"

          port {
            name           = "mysql"
            container_port = 3306
          }

          env {
            name  = "DOLT_ROOT_HOST"
            value = "%"
          }

          volume_mount {
            name       = "dolt-data"
            mount_path = "/var/lib/dolt"
          }
          volume_mount {
            name       = "init-scripts"
            mount_path = "/docker-entrypoint-initdb.d"
            read_only  = true
          }

          startup_probe {
            tcp_socket {
              port = 3306
            }
            failure_threshold = 30
            period_seconds    = 2
          }
          liveness_probe {
            tcp_socket {
              port = 3306
            }
            initial_delay_seconds = 10
            period_seconds        = 30
          }
          readiness_probe {
            tcp_socket {
              port = 3306
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          resources {
            requests = {
              memory = "256Mi"
              cpu    = "50m"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }

        volume {
          name = "dolt-data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.dolt_data.metadata[0].name
          }
        }
        volume {
          name = "init-scripts"
          config_map {
            name = kubernetes_config_map.dolt_init.metadata[0].name
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config
    ]
  }
}

resource "kubernetes_service" "dolt" {
  metadata {
    name      = "dolt"
    namespace = kubernetes_namespace.beads.metadata[0].name
    labels = {
      app = "dolt"
    }
    annotations = {
      "metallb.universe.tf/loadBalancerIPs" = "10.0.20.200"
      "metallb.io/allow-shared-ip"          = "shared"
    }
  }
  spec {
    type                    = "LoadBalancer"
    external_traffic_policy = "Cluster"
    selector = {
      app = "dolt"
    }
    port {
      name        = "mysql"
      port        = 3306
      target_port = 3306
    }
  }
}

# ── Dolt Workbench (web UI) ──

resource "kubernetes_deployment" "workbench" {
  metadata {
    name      = "dolt-workbench"
    namespace = kubernetes_namespace.beads.metadata[0].name
    labels = {
      app  = "dolt-workbench"
      tier = local.tiers.aux
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "dolt-workbench"
      }
    }
    template {
      metadata {
        labels = {
          app = "dolt-workbench"
        }
      }
      spec {
        container {
          name  = "workbench"
          image = "dolthub/dolt-workbench:latest"

          port {
            name           = "http"
            container_port = 3000
          }
          port {
            name           = "graphql"
            container_port = 9002
          }

          env {
            name  = "DATABASE_URL"
            value = "mysql://beads@dolt.beads-server.svc.cluster.local:3306/code"
          }

          startup_probe {
            http_get {
              path = "/"
              port = 3000
            }
            failure_threshold = 30
            period_seconds    = 2
          }
          liveness_probe {
            http_get {
              path = "/"
              port = 3000
            }
            initial_delay_seconds = 10
            period_seconds        = 30
          }
          readiness_probe {
            http_get {
              path = "/"
              port = 3000
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }

          resources {
            requests = {
              memory = "128Mi"
              cpu    = "10m"
            }
            limits = {
              memory = "512Mi"
            }
          }
        }
      }
    }
  }
  lifecycle {
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config
    ]
  }
}

resource "kubernetes_service" "workbench" {
  metadata {
    name      = "dolt-workbench"
    namespace = kubernetes_namespace.beads.metadata[0].name
    labels = {
      app = "dolt-workbench"
    }
  }
  spec {
    selector = {
      app = "dolt-workbench"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 3000
    }
  }
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.beads.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.beads.metadata[0].name
  name            = "dolt-workbench"
  tls_secret_name = var.tls_secret_name
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Dolt Workbench"
    "gethomepage.dev/description"  = "Beads task database UI"
    "gethomepage.dev/icon"         = "dolt.png"
    "gethomepage.dev/group"        = "Core Platform"
    "gethomepage.dev/pod-selector" = ""
  }
}
