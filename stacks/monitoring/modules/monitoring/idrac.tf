
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
        # SNMP (snmp-idrac job, dell_idrac module) is the FAST primary source
        # for dynamic + health metrics since 2026-06-05. This Redfish exporter
        # is the slow remnant (10m Prometheus scrape) serving only what SNMP
        # cannot: indicator LED, NIC link-speed Mbps, SSD life %, machine/BIOS
        # info, per-DIMM / per-NIC inventory, PSU input-watts/capacity.
        # NOTE: HA Sofia's sensor.r730_fan_speed reads idrac_sensors_fan_speed
        # from THIS exporter directly, so `sensors` MUST stay enabled.
        # events (SEL empty on this box), processors (cpu count via SNMP),
        # manager, extra -> left disabled (default false) to trim the walk.
        all: false
        system: true
        sensors: true
        power: true
        storage: true
        network: true
        memory: true
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
      # ADR-0014 service identity: monitoring is a multi-Service namespace, so
      # the namespace alone can't attribute Goldmane flows. Value = the
      # fronting Service name (kubernetes_service.idrac-redfish-exporter).
      "service-identity" = "idrac-redfish-exporter"
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
          # ADR-0014: Goldmane/Felix stamps POD labels onto flows, so the
          # disambiguating identity must live on the pod template (not just
          # the Deployment metadata above). Not in selector → no replace.
          "service-identity" = "idrac-redfish-exporter"
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
  source = "../../../../modules/kubernetes/ingress_factory"
  # Auth disabled: HA Sofia + Prometheus scrape this endpoint
  # programmatically (no browser, no SSO cookie). The
  # allow_local_access_only middleware (192.168.0.0/16 + 10.0.0.0/8)
  # already gates external access, so layering Authentik on top only
  # breaks the REST sensor in HA Sofia (it gets a 302 to authentik.viktorbarzin.me
  # and parses HTML instead of metrics).
  # auth = "none": HA Sofia REST sensors poll programmatically without cookies; Authentik OIDC flow incompatible with automation.
  auth                    = "none"
  namespace               = kubernetes_namespace.monitoring.metadata[0].name
  name                    = "idrac-redfish-exporter"
  root_domain             = "viktorbarzin.lan"
  tls_secret_name         = var.tls_secret_name
  allow_local_access_only = true
  ssl_redirect            = false
  port                    = 9090
}
