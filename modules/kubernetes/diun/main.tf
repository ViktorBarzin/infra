variable "tls_secret_name" {}
variable "diun_nfty_token" {}
variable "diun_slack_url" {}

resource "kubernetes_namespace" "diun" {
  metadata {
    name = "diun"
    labels = {
      "istio-injection" : "disabled"
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "diun"
  tls_secret_name = var.tls_secret_name
}

resource "kubernetes_service_account" "diun" {
  metadata {
    name      = "diun"
    namespace = "diun"
  }
}

resource "kubernetes_cluster_role" "diun" {
  metadata {
    name = "diun"
  }
  rule {
    api_groups = [""]
    resources  = ["pods"]
    verbs      = ["get", "watch", "list"]
  }
}
resource "kubernetes_cluster_role_binding" "diun" {
  metadata {
    name = "diun"

  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "diun"
  }
  subject {
    kind      = "ServiceAccount"
    name      = "diun"
    namespace = "diun"
  }
}

resource "kubernetes_deployment" "diun" {
  metadata {
    name      = "diun"
    namespace = "diun"
    labels = {
      app = "diun"
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
      "diun.enable"                  = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "diun"
      }
    }
    template {
      metadata {
        labels = {
          app = "diun"
        }
      }
      spec {
        service_account_name = "diun"
        container {
          image = "crazymax/diun:latest"
          name  = "diun"
          args  = ["serve"]
          env {
            name  = "TZ"
            value = "Europe/Sofia"
          }
          env {
            name  = "DIUN_WATCH_WORKERS"
            value = "20"
          }
          env {
            name  = "DIUN_WATCH_SCHEDULE"
            value = "0 */6 * * *"
          }
          env {
            name  = "DIUN_WATCH_JITTER"
            value = "30s"
          }
          env {
            name  = "DIUN_PROVIDERS_KUBERNETES"
            value = "true"
          }
          # env {
          #   name  = "DIUN_DEFAULTS_EXCLUDETAGS"
          #   value = "^.*nightly.*$"
          # }
          # env {
          #   name  = "DIUN_DEFAULTS_INCLUDETAGS"
          #   value = "^\\d+\\.\\d+\\.\\d+$"
          # }
          env {
            name  = "DIUN_DEFAULTS_WATCHREPO"
            value = "true"
            # value = "false"
          }
          env {
            name  = "DIUN_DEFAULTS_MAXTAGS"
            value = "3"
          }
          env {
            name  = "DIUN_DEFAULTS_SORTTAGS"
            value = "reverse"
          }
          # DIUN_PROVIDERS_KUBERNETES_WATCHBYDEFAULT = "true" ??

          // ntfy settings
          # env { // disabled as if this fails, no other notifications are sent
          #   name  = "DIUN_NOTIF_NTFY_ENDPOINT"
          #   value = "https://ntfy.viktorbarzin.me"
          # }
          # env {
          #   name  = "DIUN_NOTIF_NTFY_TOPIC"
          #   value = "diun-updates"
          # }
          # env {
          #   name  = "DIUN_NOTIF_NTFY_TOKEN"
          #   value = var.diun_nfty_token
          # }
          env {
            name  = "DIUN_NOTIF_SLACK_WEBHOOKURL"
            value = var.diun_slack_url
          }
          env {
            name = "LOG_LEVEL"
            # value = "info"
            value = "debug"
          }
          # env {
          #   name  = "DIUN_WATCH_FIRSTCHECKNOTIF"
          #   value = "true"  # send notfication on start; subsequent checks check for newer versions and is what you need
          # }
          # env {
          #   name  = "DIUN_NOTIF_NTFY_TIMEOUT"
          #   value = "10s"
          # }
          volume_mount {
            name       = "data"
            mount_path = "/data"
          }
        }
        volume {
          name = "data"
          nfs {
            path   = "/mnt/main/diun"
            server = "10.0.10.15"
          }
        }
      }
    }
  }
}

