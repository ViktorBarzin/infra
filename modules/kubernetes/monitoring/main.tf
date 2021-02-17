variable "tls_secret_name" {}
variable "alertmanager_account_password" {}

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

  values = [templatefile("${path.module}/prometheus_chart_values.tpl", { alertmanager_mail_pass = var.alertmanager_account_password })]
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
