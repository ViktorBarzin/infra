variable "tls_secret_name" {}
variable "alertmanager_account_password" {}
variable "idrac_host" {
  default = "idrac"
}
variable "idrac_username" {
  default = "root"
}
variable "idrac_password" {
  default = "calvin"
}
variable "alertmanager_slack_api_url" {}

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "monitoring"
  tls_secret_name = var.tls_secret_name
}

resource "helm_release" "prometheus" {
  namespace        = "monitoring"
  create_namespace = true
  name             = "prometheus"

  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus"
  version    = "15.0.2"

  values = [templatefile("${path.module}/prometheus_chart_values.tpl", { alertmanager_mail_pass = var.alertmanager_account_password, alertmanager_slack_api_url = var.alertmanager_slack_api_url })]
}

# Terraform get angry with the 30k values file :/ use ansible until solved
# resource "helm_release" "prometheus_snmp_exporter" {
#   namespace        = "monitoring"
#   create_namespace = true
#   name             = "prometheus_exporter"

#   repository = "https://prometheus-community.github.io/helm-charts"
#   chart      = "prometheus-snmp-exporter"

#   values = [file("${path.module}/prometheus_snmp_chart_values.yaml")]
# }

resource "kubernetes_secret" "prometheus_grafana_datasource" {
  metadata {
    name      = "prometheus-grafana-datasource"
    namespace = "monitoring"

    labels = {
      grafana_datasource = "1"
    }
  }

  data = {
    "datasource.yaml" = <<EOT
# config file version
apiVersion: 1

# list of datasources that should be deleted from the database
#deleteDatasources:
# - name: Prometheus
#   orgId: 1

# list of datasources to insert/update depending
# whats available in the database
datasources:
  # <string, required> name of the datasource. Required
- name: Prometheus
  # <string, required> datasource type. Required
  type: prometheus
  # <string, required> access mode. proxy or direct (Server or Browser in the UI). Required
  access: proxy
  # <int> org id. will default to orgId 1 if not specified
  orgId: 1
  # <string> url
  url: http://prometheus-server
  # <string> database password, if used
  password:
  # <string> database user, if used
  user:
  # <string> database name, if used
  database:
  # <bool> enable/disable basic auth
  basicAuth:
  # <string> basic auth username
  basicAuthUser:
  # <string> basic auth password
  basicAuthPassword:
  # <bool> enable/disable with credentials headers
  withCredentials:
  # <bool> mark as default datasource. Max one per org
  isDefault:
  # <map> fields that will be converted to json and stored in json_data
  #jsonData:
  #  graphiteVersion: \"1.1\"
  #  tlsAuth: true
  #  tlsAuthWithCACert: true
  # <string> json object of data that will be encrypted.
  #secureJsonData:
  #  tlsCACert: \"...\"
  #  tlsClientCert: \"...\"
  #  tlsClientKey: \"...\"
  version: 1
  # <bool> allow users to edit datasources from the UI.
  editable: false
  EOT
  }

  type = "Opaque"
}

resource "kubernetes_persistent_volume" "prometheus_grafana_pv" {
  metadata {
    name = "grafana-iscsi-pv"
  }
  spec {
    capacity = {
      "storage" = "2Gi"
    }
    access_modes = ["ReadWriteOnce"]
    persistent_volume_source {
      iscsi {
        target_portal = "iscsi.viktorbarzin.lan:3260"
        iqn           = "iqn.2020-12.lan.viktorbarzin:storage:monitoring:grafana"
        lun           = 0
        fs_type       = "ext4"
      }
    }
  }
}
resource "kubernetes_persistent_volume_claim" "prometheus_grafana_pvc" {
  metadata {
    name      = "grafana-iscsi-pvc"
    namespace = "monitoring"
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        "storage" = "2Gi"
      }
    }
  }
}

resource "helm_release" "grafana" {
  namespace        = "monitoring"
  create_namespace = true
  name             = "grafana"

  repository = "https://grafana.github.io/helm-charts"
  chart      = "grafana"

  values = [file("${path.module}/grafana_chart_values.yaml")]
}

resource "kubernetes_cron_job" "monitor_prom" {
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
    namespace = "monitoring"
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
    namespace = "monitoring"
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

resource "kubernetes_config_map" "redfish-config" {
  metadata {
    name      = "redfish-exporter-config"
    namespace = "monitoring"
  }
  data = {
    "config.yml" = <<-EOF
      hosts:
        ${var.idrac_host}:
          username: ${var.idrac_username}
          password: ${var.idrac_password}
        default:
          username: root
          password: calvin
      groups:
        group1:
          username: user
          password: pass
    EOF
  }
}

resource "kubernetes_deployment" "idrac-redfish" {
  metadata {
    name      = "idrac-redfish-exporter"
    namespace = "monitoring"
    labels = {
      app = "idrac-redfish-exporter"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "idrac-redfish-exporter"
      }
    }
    template {
      metadata {
        labels = {
          app = "idrac-redfish-exporter"
        }
      }
      spec {
        container {
          image   = "viktorbarzin/redfish-exporter:latest"
          name    = "redfish-exporter"
          command = ["/bin/sh", "-c", "redfish-exporter --config.file /app/config.yml"]
          port {
            container_port = 9610
          }

          volume_mount {
            name       = "redfish-exporter-config"
            mount_path = "/app/config.yml"
            sub_path   = "config.yml"
          }
        }
        volume {
          name = "redfish-exporter-config"
          config_map {
            name = "redfish-exporter-config"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "idrac-redfish-exporter" {
  metadata {
    name      = "idrac-redfish-exporter"
    namespace = "monitoring"
    labels = {
      "app" = "idrac-redfish-exporter"
    }
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/path"   = "/metrics"
      "prometheus.io/port"   = "9090"
    }
  }

  spec {
    selector = {
      "app" = "idrac-redfish-exporter"
    }
    port {
      name        = "http"
      port        = "9090"
      target_port = "9610"
    }
  }
}
