variable "tls_secret_name" {
  type      = string
  sensitive = true
}
variable "nfs_server" { type = string }
variable "mysql_host" { type = string }

resource "kubernetes_namespace" "speedtest" {
  metadata {
    name = "speedtest"
    labels = {
      tier = local.tiers.aux
    }
  }
}

resource "kubernetes_manifest" "external_secret" {
  manifest = {
    apiVersion = "external-secrets.io/v1beta1"
    kind       = "ExternalSecret"
    metadata = {
      name      = "speedtest-secrets"
      namespace = "speedtest"
    }
    spec = {
      refreshInterval = "15m"
      secretStoreRef = {
        name = "vault-database"
        kind = "ClusterSecretStore"
      }
      target = {
        name = "speedtest-secrets"
      }
      data = [{
        secretKey = "db_password"
        remoteRef = {
          key      = "static-creds/mysql-speedtest"
          property = "password"
        }
      }]
    }
  }
  depends_on = [kubernetes_namespace.speedtest]
}

module "tls_secret" {
  source          = "../../modules/kubernetes/setup_tls_secret"
  namespace       = kubernetes_namespace.speedtest.metadata[0].name
  tls_secret_name = var.tls_secret_name
}

resource "random_id" "secret_key" {
  byte_length = 32 # 32 bytes × 2 hex chars = 64 hex characters
}

resource "kubernetes_persistent_volume_claim" "config_proxmox" {
  wait_until_bound = false
  metadata {
    name      = "speedtest-config-proxmox"
    namespace = kubernetes_namespace.speedtest.metadata[0].name
    annotations = {
      "resize.topolvm.io/threshold"     = "80%"
      "resize.topolvm.io/increase"      = "100%"
      "resize.topolvm.io/storage_limit" = "5Gi"
    }
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "proxmox-lvm"
    resources {
      requests = {
        storage = "1Gi"
      }
    }
  }
}

resource "kubernetes_deployment" "speedtest" {
  metadata {
    name      = "speedtest"
    namespace = kubernetes_namespace.speedtest.metadata[0].name
    labels = {
      app  = "speedtest"
      tier = local.tiers.aux
    }
    annotations = {
      "reloader.stakater.com/auto" = "true"
    }
  }
  spec {
    replicas = 1
    strategy {
      type = "Recreate"
    }
    selector {
      match_labels = {
        app = "speedtest"
      }
    }
    template {
      metadata {
        labels = {
          app = "speedtest"
        }
        annotations = {
          "diun.enable"                    = "true"
          "diun.include_tags"              = "^\\d+\\.\\d+\\.\\d+$"
          "dependency.kyverno.io/wait-for" = "mysql.dbaas:3306"
        }
      }
      spec {
        container {
          image = "lscr.io/linuxserver/speedtest-tracker:0.24.1"
          name  = "speedtest"
          port {
            container_port = 80
          }
          env {
            name  = "PUID"
            value = 1000
          }
          env {
            name  = "PGID"
            value = 1000
          }
          env {
            name  = "APP_KEY"
            value = "base64:${random_id.secret_key.b64_std}"
          }
          env {
            name  = "SPEEDTEST_SCHEDULE"
            value = "0 * * * *"
          }
          #   env {
          #     name = "SPEEDTEST_SERVERS"
          #     # Sofia speedtest servers - https://c.speedtest.net/speedtest-servers-static.php
          #     value = "7617,17787,11348,37980,54640,27843,57118,10754,20191,29617"
          #   }
          env {
            name  = "APP_URL"
            value = "https://speedtest.viktorbarzin.me"
          }
          env {
            name  = "DB_CONNECTION"
            value = "mysql"
          }
          env {
            name  = "DB_HOST"
            value = var.mysql_host
          }
          env {
            name  = "DB_DATABASE"
            value = "speedtest"
          }
          env {
            name  = "DB_USERNAME"
            value = "speedtest"
          }
          env {
            name = "DB_PASSWORD"
            value_from {
              secret_key_ref {
                name = "speedtest-secrets"
                key  = "db_password"
              }
            }
          }
          env {
            name  = "DB_PORT"
            value = "3306"
          }
          env {
            name  = "APP_TIMEZONE"
            value = "Europe/Sofia"
          }
          resources {
            requests = {
              cpu    = "25m"
              memory = "128Mi"
            }
            limits = {
              memory = "512Mi"
            }
          }
          volume_mount {
            name       = "config"
            mount_path = "/config"
          }
        }
        volume {
          name = "config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.config_proxmox.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "speedtest" {
  metadata {
    name      = "speedtest"
    namespace = kubernetes_namespace.speedtest.metadata[0].name
    labels = {
      "app" = "speedtest"
    }
    annotations = {
      "prometheus.io/scrape" = "false"
    }
  }

  spec {
    selector = {
      app = "speedtest"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 80
    }
  }
}

module "ingress" {
  source          = "../../modules/kubernetes/ingress_factory"
  namespace       = kubernetes_namespace.speedtest.metadata[0].name
  name            = "speedtest"
  tls_secret_name = var.tls_secret_name
  protected       = true
  extra_annotations = {
    "gethomepage.dev/enabled"      = "true"
    "gethomepage.dev/name"         = "Speedtest"
    "gethomepage.dev/description"  = "Internet speed tracker"
    "gethomepage.dev/icon"         = "speedtest-tracker.png"
    "gethomepage.dev/group"        = "Infrastructure"
    "gethomepage.dev/widget.type"  = "speedtest"
    "gethomepage.dev/widget.url"   = "http://speedtest.speedtest.svc.cluster.local"
    "gethomepage.dev/pod-selector" = ""
  }
}
