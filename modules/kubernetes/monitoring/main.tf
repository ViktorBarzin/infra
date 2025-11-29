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

module "tls_secret" {
  source          = "../setup_tls_secret"
  namespace       = "monitoring"
  tls_secret_name = var.tls_secret_name
}
resource "kubernetes_persistent_volume_claim" "prometheus_server_pvc" {
  metadata {
    name      = "prometheus-iscsi-pvc"
    namespace = "monitoring"
  }

  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = "15Gi"
      }
    }
    # storage_class_name = "standard"
    volume_name = "prometheus-iscsi-pv"
  }
}

resource "kubernetes_persistent_volume" "prometheus_server_pvc" {
  metadata {
    name = "prometheus-iscsi-pv"
  }
  spec {
    capacity = {
      storage = "15Gi"
    }
    access_modes = ["ReadWriteOnce"]
    persistent_volume_source {
      nfs {
        path   = "/mnt/main/prometheus"
        server = "10.0.10.15"
      }
      # iscsi {
      #   fs_type       = "ext4"
      #   iqn           = "iqn.2020-12.lan.viktorbarzin:storage:monitoring:prometheus"
      #   lun           = 0
      #   target_portal = "iscsi.viktorbarzin.me:3260"
      # }

    }
    persistent_volume_reclaim_policy = "Retain"
    volume_mode                      = "Filesystem"
  }
}

resource "helm_release" "prometheus" {
  namespace        = "monitoring"
  create_namespace = true
  name             = "prometheus"

  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus"
  # version    = "15.0.2"
  version = "25.8.2"

  values = [templatefile("${path.module}/prometheus_chart_values.tpl", { alertmanager_mail_pass = var.alertmanager_account_password, alertmanager_slack_api_url = var.alertmanager_slack_api_url, tuya_api_key = var.tiny_tuya_service_secret, haos_api_token = var.haos_api_token })]
}

# Terraform get angry with the 30k values file :/ use ansible until solved
# resource "helm_release" "ups_prometheus_snmp_exporter" {
#   namespace        = "monitoring"
#   create_namespace = true
#   name             = "ups_prometheus_exporter"

#   repository = "https://prometheus-community.github.io/helm-charts"
#   chart      = "prometheus-snmp-exporter"

#   values = [file("${path.module}/ups_snmp_values.yaml")]
# }

# resource "kubernetes_secret" "prometheus_grafana_datasource" {
#   metadata {
#     name      = "prometheus-grafana-datasource"
#     namespace = "monitoring"

#     labels = {
#       grafana_datasource = "1"
#     }
#   }

#   data = {
#     "datasource.yaml" = <<EOT
# # config file version
# apiVersion: 1

# # list of datasources that should be deleted from the database
# #deleteDatasources:
# # - name: Prometheus
# #   orgId: 1

# # list of datasources to insert/update depending
# # whats available in the database
# datasources:
#   # <string, required> name of the datasource. Required
# - name: Prometheus
#   # <string, required> datasource type. Required
#   type: prometheus
#   # <string, required> access mode. proxy or direct (Server or Browser in the UI). Required
#   access: proxy
#   # <int> org id. will default to orgId 1 if not specified
#   orgId: 1
#   # <string> url
#   url: http://prometheus-server
#   # <string> database password, if used
#   password:
#   # <string> database user, if used
#   user:
#   # <string> database name, if used
#   database:
#   # <bool> enable/disable basic auth
#   basicAuth:
#   # <string> basic auth username
#   basicAuthUser:
#   # <string> basic auth password
#   basicAuthPassword:
#   # <bool> enable/disable with credentials headers
#   withCredentials:
#   # <bool> mark as default datasource. Max one per org
#   isDefault:
#   # <map> fields that will be converted to json and stored in json_data
#   #jsonData:
#   #  graphiteVersion: \"1.1\"
#   #  tlsAuth: true
#   #  tlsAuthWithCACert: true
#   # <string> json object of data that will be encrypted.
#   #secureJsonData:
#   #  tlsCACert: \"...\"
#   #  tlsClientCert: \"...\"
#   #  tlsClientKey: \"...\"
#   version: 1
#   # <bool> allow users to edit datasources from the UI.
#   editable: false
#   EOT
#   }

#   type = "Opaque"
# }

resource "kubernetes_persistent_volume" "prometheus_grafana_pv" {
  metadata {
    name = "grafana-pv"
  }
  spec {
    capacity = {
      "storage" = "2Gi"
    }
    access_modes = ["ReadWriteOnce"]
    persistent_volume_source {
      nfs {
        path   = "/mnt/main/grafana"
        server = "10.0.10.15"
      }
      # iscsi {
      #   target_portal = "iscsi.viktorbarzin.lan:3260"
      #   iqn           = "iqn.2020-12.lan.viktorbarzin:storage:monitoring:grafana"
      #   lun           = 0
      #   fs_type       = "ext4"
      # }
    }
  }
}

resource "kubernetes_persistent_volume" "alertmanager_pv" {
  metadata {
    name = "alertmanager-pv"
  }
  spec {
    capacity = {
      "storage" = "2Gi"
    }
    access_modes = ["ReadWriteOnce"]
    persistent_volume_source {
      nfs {
        path   = "/mnt/main/alertmanager"
        server = "10.0.10.15"
      }
    }
  }
}
resource "kubernetes_persistent_volume_claim" "grafana_pvc" {
  metadata {
    name      = "grafana-pvc"
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
  atomic           = true

  repository = "https://grafana.github.io/helm-charts"
  chart      = "grafana"

  values = [file("${path.module}/grafana_chart_values.yaml")]
}

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

    annotations = {
      "reloader.stakater.com/match" = "true"
    }
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
    annotations = {
      "reloader.stakater.com/search" = "true"
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
          image = "viktorbarzin/redfish-exporter:latest"
          name  = "redfish-exporter"
          # command = ["/bin/sh", "-c", "redfish-exporter --config.file /app/config.yml"]
          # command = ["/usr/local/bin/redfish_exporter", "--config.file", "/etc/prometheus/redfish_exporter.yml"]
          command = ["/usr/local/bin/redfish_exporter", "--config.file", "/app/config.yml"]
          port {
            container_port = 9610
          }

          volume_mount {
            name       = "redfish-exporter-config"
            mount_path = "/app/config.yml"
            # mount_path = "/etc/prometheus/redfish_exporter.yml"
            sub_path = "config.yml"
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


/**
1. clone snmp exporter
2. update generator.yaml to include only interesting modules
3. make generate
4. cp snmp.yml to whereever is used
5. scrape service with curl 'http://snmp-exporter.monitoring.svc.cluster.local:9116/snmp?auth=public_v2&module=huawei&target=192.168.1.5%3A161'

generate reference - https://github.com/prometheus/snmp_exporter/tree/main/generator
https://sbcode.net/prometheus/snmp-generate-huawei/
*/
resource "kubernetes_config_map" "snmp-exporter-yaml" {
  metadata {
    name      = "snmp-exporter-yaml"
    namespace = "monitoring"

    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }
  data = {
    "snmp.yml" = file("${path.module}/ups_snmp_values.yaml")

  }
}

resource "kubernetes_deployment" "snmp-exporter" {
  metadata {
    name      = "snmp-exporter"
    namespace = "monitoring"
    labels = {
      app = "snmp-exporter"
    }
    annotations = {
      "reloader.stakater.com/search" = "true"
    }
  }
  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "snmp-exporter"
      }
    }
    template {
      metadata {
        labels = {
          app = "snmp-exporter"
        }
      }
      spec {
        container {
          image = "prom/snmp-exporter"
          name  = "snmp-exporter"
          # command = ["/usr/local/bin/redfish_exporter", "--config.file", "/app/config.yml"]
          port {
            container_port = 9116
          }

          volume_mount {
            name       = "config-volume"
            mount_path = "/etc/snmp_exporter/"
          }
        }
        volume {
          name = "config-volume"

          config_map {
            name = "snmp-exporter-yaml"
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "snmp-exporter" {
  metadata {
    name      = "snmp-exporter"
    namespace = "monitoring"
    labels = {
      "app" = "snmp-exporter"
    }
    annotations = {
      "prometheus.io/scrape" = "true"
      "prometheus.io/path"   = "/snmp?auth=Public0&target=tcp%3A%2F%2F192.%3A161"
      "prometheus.io/port"   = "9116"
    }
  }

  spec {
    selector = {
      "app" = "snmp-exporter"
    }
    port {
      name        = "http"
      port        = "9116"
      target_port = "9116"
    }
  }
}

# resource "helm_release" "loki" {
#   namespace        = "monitoring"
#   create_namespace = true
#   name             = "loki"

#   repository = "https://grafana.github.io/helm-charts"
#   chart      = "loki"

#   values  = [templatefile("${path.module}/loki.yaml", {})]
#   atomic  = true
#   timeout = 120
# }

resource "kubernetes_persistent_volume" "loki" {
  metadata {
    name = "loki"
  }
  spec {
    capacity = {
      storage = "15Gi"
    }
    access_modes = ["ReadWriteOnce"]
    persistent_volume_source {
      nfs {
        path   = "/mnt/main/loki/loki"
        server = "10.0.10.15"
      }
    }
    persistent_volume_reclaim_policy = "Retain"
    volume_mode                      = "Filesystem"
  }
}

resource "kubernetes_persistent_volume" "loki-minio" {
  metadata {
    name = "loki-minio"
  }
  spec {
    capacity = {
      storage = "15Gi"
    }
    access_modes = ["ReadWriteMany"]
    persistent_volume_source {
      nfs {
        path   = "/mnt/main/loki/minio"
        server = "10.0.10.15"
      }
    }
    persistent_volume_reclaim_policy = "Retain"
    volume_mode                      = "Filesystem"
  }
}


# https://grafana.com/docs/alloy/latest/configure/kubernetes/
# resource "helm_release" "alloy" {
#   namespace        = "monitoring"
#   create_namespace = true
#   name             = "alloy"

#   repository = "https://grafana.github.io/helm-charts"
#   chart      = "alloy"

#   atomic = true
# }

# Increase open file limits as alloy is reading files:
# https://serverfault.com/questions/1137211/failed-to-create-fsnotify-watcher-too-many-open-files

# run for all nodes using :
# for n in $(kbn | awk '{print $1}'); do echo $n; s wizard@$n 'sudo sysctl -w fs.inotify.max_user_watches=2099999999; sudo sysctl -w fs.inotify.max_user_instances=2099999999;sudo sysctl -w fs.inotify.max_queued_events=2099999999'; done

# resource "helm_release" "k8s-monitoring" {
#   namespace        = "monitoring"
#   create_namespace = true
#   name             = "k8s-monitoring"

#   repository = "https://grafana.github.io/helm-charts"
#   chart      = "k8s-monitoring"

#   values = [templatefile("${path.module}/k8s-monitoring-values.yaml", {})]
#   atomic = true
# }
