variable "tls_secret_name" {}
variable "alertmanager_account_password" {}
variable "idrac_host" {
  default = "192.168.1.4"
}
variable "idrac_username" {
  default = "root"
}
variable "idrac_password" {
  default = "calvin"
}
variable "alertmanager_slack_api_url" {}
variable "tiny_tuya_service_secret" { type = string }
variable "haos_api_token" { type = string }
variable "pve_password" { type = string }
variable "grafana_db_password" { type = string }
variable "tier" { type = string }

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      "istio-injection" : "disabled"
      tier = var.tier
    }
  }
}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = kubernetes_namespace.monitoring.metadata[0].name
  tls_secret_name = var.tls_secret_name
}
# Terraform get angry with the 30k values file :/ use ansible until solved
# resource "helm_release" "ups_prometheus_snmp_exporter" {
#  namespace = kubernetes_namespace.monitoring.metadata[0].name
#   create_namespace = true
#   name             = "ups_prometheus_exporter"

#   repository = "https://prometheus-community.github.io/helm-charts"
#   chart      = "prometheus-snmp-exporter"

#   values = [file("${path.module}/ups_snmp_values.yaml")]
# }



resource "kubernetes_cron_job_v1" "monitor_prom" {
  metadata {
    name = "monitor-prometheus"
  }
  spec {
    concurrency_policy        = "Replace"
    failed_jobs_history_limit = 5
    schedule                  = "*/30 * * * *"
    job_template {
      metadata {

      }
      spec {
        template {
          metadata {

          }
          spec {
            container {
              name    = "monitor-prometheus"
              image   = "alpine"
              command = ["/bin/sh", "-c", "apk add --update curl && curl --connect-timeout 2 prometheus-server.monitoring.svc.cluster.local || curl https://webhook.viktorbarzin.me/fb/message-viktor -d 'Prometheus is down!'"]
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_ingress_v1" "status" {
  metadata {
    name      = "hetrix-redirect-ingress"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    annotations = {
      "kubernetes.io/ingress.class"                    = "nginx"
      "nginx.ingress.kubernetes.io/permanent-redirect" = "https://hetrixtools.com/r/38981b548b5d38b052aca8d01285a3f3/"
    }
  }

  spec {
    tls {
      hosts       = ["status.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "status.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "not-used"
              port {
                number = 80 # redirected by annotation
              }
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_ingress_v1" "status_yotovski" {
  metadata {
    name      = "hetrix-yotovski-redirect-ingress"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    annotations = {
      "kubernetes.io/ingress.class"                    = "nginx"
      "nginx.ingress.kubernetes.io/permanent-redirect" = "https://hetrixtools.com/r/2ba9d7a5e017794db0fd91f0115a8b3b/"
    }
  }

  spec {
    tls {
      hosts       = ["yotovski-status.viktorbarzin.me"]
      secret_name = var.tls_secret_name
    }
    rule {
      host = "yotovski-status.viktorbarzin.me"
      http {
        path {
          path = "/"
          backend {
            service {
              name = "not-used" # redirected by annotation
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}

