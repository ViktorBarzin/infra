
resource "kubernetes_config_map" "redfish-config" {
  metadata {
    name      = "redfish-exporter-config"
    namespace = kubernetes_namespace.monitoring.metadata[0].name

    annotations = {
      "reloader.stakater.com/match" = "true"
    }
  }
  data = {
    "config.yml" = <<-EOF
      address: 0.0.0.0
      port: 9610
      hosts:
        ${var.idrac_host}:
          username: ${var.idrac_username}
          password: ${var.idrac_password}
        default:
          username: root
          password: calvin
      metrics:
        all: true
        # system: true
        # sensors: true
        # power: true
        # sel: false        # Disable SEL - often slow
        # storage: true    # Disable storage - slowest endpoint
        # memory: true
        # network: false    # Disable network adapters
        # firmware: false   # Don't need this frequently
    EOF
  }
}

resource "kubernetes_deployment" "idrac-redfish" {
  metadata {
    name      = "idrac-redfish-exporter"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      app  = "idrac-redfish-exporter"
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
        priority_class_name = "tier-1-cluster"
        container {
          # https://github.com/mrlhansen/idrac_exporter?tab=readme-ov-file
          # Patched v2.4.1 - restored missing idrac_power_supply_input_voltage metric
          # See: https://github.com/mrlhansen/idrac_exporter/issues/176
          image = "viktorbarzin/idrac-redfish-exporter:2.4.1-voltage-fix"
          name  = "redfish-exporter"
          port {
            container_port = 9610
          }

          volume_mount {
            name       = "redfish-exporter-config"
            mount_path = "/etc/prometheus/idrac.yml"
            sub_path   = "config.yml"
          }
        }
        volume {
          name = "redfish-exporter-config"
          config_map {
            name = "redfish-exporter-config"
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
  lifecycle {
    # KYVERNO_LIFECYCLE_V1: Kyverno admission webhook mutates dns_config with ndots=2
    ignore_changes = [spec[0].template[0].spec[0].dns_config]
  }
}

resource "kubernetes_service" "idrac-redfish-exporter" {
  metadata {
    name      = "idrac-redfish-exporter"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      "app" = "idrac-redfish-exporter"
    }
    # annotations = {
    #   "prometheus.io/scrape" = "true"
    #   "prometheus.io/path"   = "/metrics"
    #   "prometheus.io/port"   = "9090"
    # }
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

module "idrac-redfish-exporter-ingress" {
  source                  = "../../../../modules/kubernetes/ingress_factory"
  namespace               = kubernetes_namespace.monitoring.metadata[0].name
  name                    = "idrac-redfish-exporter"
  root_domain             = "viktorbarzin.lan"
  tls_secret_name         = var.tls_secret_name
  allow_local_access_only = true
  ssl_redirect            = false
  port                    = 9090
}
