
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
    namespace = kubernetes_namespace.monitoring.metadata[0].name

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
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      app  = "snmp-exporter"
      tier = var.tier
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
    namespace = kubernetes_namespace.monitoring.metadata[0].name
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

module "snmp-exporter-ingress" {
  source                  = "../ingress_factory"
  namespace               = kubernetes_namespace.monitoring.metadata[0].name
  name                    = "snmp-exporter"
  root_domain             = "viktorbarzin.lan"
  tls_secret_name         = var.tls_secret_name
  allow_local_access_only = true
  ssl_redirect            = false
  port                    = 9116
}
