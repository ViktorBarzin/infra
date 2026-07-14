
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
      # ADR-0014 service identity: monitoring is a multi-Service namespace, so
      # the namespace alone can't attribute Goldmane flows. Value = the
      # fronting Service name (kubernetes_service.snmp-exporter).
      "service-identity" = "snmp-exporter"
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
          # ADR-0014: Goldmane/Felix stamps POD labels onto flows, so the
          # disambiguating identity must live on the pod template (not just
          # the Deployment metadata above). Not in selector → no replace.
          "service-identity" = "snmp-exporter"
        }
      }
      spec {
        container {
          image = "prom/snmp-exporter"
          name  = "snmp-exporter"
          # command = ["/usr/local/bin/redfish_exporter", "--config.file", "/app/config.yml"]

          resources {
            requests = {
              cpu    = "10m"
              memory = "256Mi"
            }
            limits = {
              memory = "256Mi"
            }
          }

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

resource "kubernetes_service" "snmp-exporter" {
  metadata {
    name      = "snmp-exporter"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
    labels = {
      "app" = "snmp-exporter"
    }
    # annotations = {
    #   "prometheus.io/scrape" = "true"
    #   "prometheus.io/path"   = "/snmp?auth=Public0&target=tcp%3A%2F%2F192.%3A161"
    #   "prometheus.io/port"   = "9116"
    # }
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
  source = "../../../../modules/kubernetes/ingress_factory"
  # Auth disabled — same rationale as idrac-redfish-exporter-ingress:
  # HA Sofia REST sensors scrape /snmp endpoint programmatically and
  # can't follow the Authentik OIDC flow. local-only IP allowlist
  # already gates external access.
  # auth = "none": HA Sofia REST sensors scrape /snmp endpoint programmatically; OIDC flow would 302 every request.
  auth                    = "none"
  namespace               = kubernetes_namespace.monitoring.metadata[0].name
  name                    = "snmp-exporter"
  root_domain             = "viktorbarzin.lan"
  tls_secret_name         = var.tls_secret_name
  allow_local_access_only = true
  ssl_redirect            = false
  port                    = 9116
  extra_annotations = {
    "gethomepage.dev/icon" = "mdi-lan"
  }
}
