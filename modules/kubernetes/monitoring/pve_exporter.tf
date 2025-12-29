
resource "kubernetes_secret" "pve_exporter_config" {
  metadata {
    name      = "pve-exporter-config"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    "pve.yml" = <<-EOF
      default:
          user: "root@pam"
          password: ${var.pve_password}
          verify_ssl: false
          timeout: 30
    EOF
  }
}

resource "kubernetes_deployment" "pve_exporter" {
  metadata {
    name      = "proxmox-exporter"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "proxmox-exporter"
      }
    }

    template {
      metadata {
        labels = {
          app = "proxmox-exporter"
        }
      }

      spec {
        container {
          name  = "proxmox-exporter"
          image = "prompve/prometheus-pve-exporter:latest"

          port {
            container_port = 9221
          }

          # Mount the file into the container
          volume_mount {
            name       = "config-volume"
            mount_path = "/etc/prometheus"
            read_only  = true
          }
        }

        volume {
          name = "config-volume"
          secret {
            secret_name = kubernetes_secret.pve_exporter_config.metadata[0].name
            items {
              key  = "pve.yml"
              path = "pve.yml" # This results in /etc/prometheus/pve.yml
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "proxmox-exporter" {
  metadata {
    name      = "proxmox-exporter"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      "app" = "proxmox-exporter"
    }
    annotations = {
      "prometheus.io/scrape"        = "true"
      "prometheus.io/port"          = 9221
      "prometheus.io/path"          = "/pve"
      "prometheus.io/param_target"  = "192.168.1.127"
      "prometheus.io/param_node"    = "1"
      "prometheus.io/param_cluster" = "1"
    }
  }

  spec {
    selector = {
      "app" = "proxmox-exporter"
    }
    port {
      name        = "http"
      port        = 9221
      target_port = 9221
    }
  }
}

# To monitor the pve node, use the node exporter and the playbook in this repo. from the root run:
# ansible-playbook -i ./playbooks/inventory.ini  ./playbooks/deploy_node_exporter.yaml
# This installs the exporter binary
