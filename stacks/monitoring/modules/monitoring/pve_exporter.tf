
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
    labels = {
      tier = var.tier
    }
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

          resources {
            requests = {
              cpu    = "15m"
              memory = "256Mi"
            }
            limits = {
              memory = "256Mi"
            }
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
    # KEEL: monitoring ns is keel-enrolled (policy=patch) — Keel owns the image
    # tag and injects keel.sh annotations. Ignore so TF stops reverting Keel each
    # plan (completes the cdb7d9a8 KEEL sweep that missed these exporters and was
    # tripping drift-detection exit 2 every run). 2026-05-31.
    ignore_changes = [
      spec[0].template[0].spec[0].dns_config,
      spec[0].template[0].spec[0].container[0].image, # KEEL_IGNORE_IMAGE
      metadata[0].annotations["keel.sh/policy"],
      metadata[0].annotations["keel.sh/trigger"],
      metadata[0].annotations["keel.sh/pollSchedule"],
      metadata[0].annotations["keel.sh/match-tag"],
      spec[0].template[0].metadata[0].annotations["keel.sh/update-time"], # KEEL_LIFECYCLE_V1
    ]
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
      # Use scrape_slow (5m interval, 30s timeout in prometheus values) because
      # the PVE API endpoint regularly takes ~11s with ~1000 k8s-csi LVs on the
      # host, blowing past the default 10s scrape_timeout and flapping the
      # ProxmoxMetricsMissing + ScrapeTargetDown alerts. The slow job is gated
      # by the `prometheus_io_scrape_slow=true` annotation in
      # prometheus_chart_values.tpl and also excludes us from the fast job.
      "prometheus.io/scrape_slow"   = "true"
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
